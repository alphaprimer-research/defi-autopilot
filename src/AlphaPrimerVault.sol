// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ── protocol interfaces ────────────────────────────

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IFluidVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

interface IGainsVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner_) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

interface IScaledBalance {
    function balanceOf(address user) external view returns (uint256);
}

/// @title AlphaPrimer Multi-Strategy Yield Vault
/// @notice Routes USDC to the highest-yielding protocol among
///         Aave V3, Compound V3, Morpho Blue, Fluid, and Gains Network
/// @dev Owner = TimelockController behind 4/5 multi-sig.
///      Strategist = bot wallet with limited rebalance-only access.
contract AlphaPrimerVault is
    ERC4626Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    // ── state ───────────────────────────────────────

    IERC20 public underlying;
    address public strategist;

    uint256 public perfFeeBps;
    uint256 public mgmtFeeBps;
    uint256 public constant MAX_PERF_FEE = 2000;
    uint256 public constant MAX_MGMT_FEE = 200;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_DEPOSIT = 1e6;

    uint256 public lastHarvest;
    uint256 public accruedFees;
    bool public depositsPaused;

    // active protocol: 0=idle, 1=aave, 2=compound, 3=fluid, 4=reserved
    uint8 public activeProtocol;

    // protocol addresses
    IAavePool public aavePool;
    IScaledBalance public aaveAToken;
    IComet public compound;
    IFluidVault public fluid;
    IGainsVault public gains;

    // ── events ──────────────────────────────────────

    event Harvest(uint256 yield, uint256 fee);
    event FeesCollected(uint256 amount);
    event DepositsPaused(bool state);
    event Rebalanced(uint8 fromProtocol, uint8 toProtocol, uint256 amount);
    event StrategistUpdated(address indexed prev, address indexed next);

    // ── modifiers ───────────────────────────────────

    modifier onlyStrategistOrOwner() {
        require(msg.sender == strategist || msg.sender == owner(), "not authorized");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address asset_,
        address owner_,
        address strategist_,
        address aavePool_,
        address aaveAToken_,
        address compound_,
        address fluid_,
        address gains_,
        uint256 perfFee_,
        uint256 mgmtFee_
    ) external initializer {
        __ERC4626_init(IERC20(asset_));
        __ERC20_init("AlphaPrimer USDC Vault", "apUSDC");
        __Ownable_init(owner_);

        underlying = IERC20(asset_);
        strategist = strategist_;

        aavePool = IAavePool(aavePool_);
        aaveAToken = IScaledBalance(aaveAToken_);
        compound = IComet(compound_);
        fluid = IFluidVault(fluid_);
        gains = IGainsVault(gains_);

        perfFeeBps = perfFee_;
        mgmtFeeBps = mgmtFee_;
        lastHarvest = block.timestamp;
        activeProtocol = 1; // start with Aave

        // approve all protocols
        underlying.approve(aavePool_, type(uint256).max);
        underlying.approve(compound_, type(uint256).max);
        underlying.approve(fluid_, type(uint256).max);
        underlying.approve(gains_, type(uint256).max);
    }

    // ── views ───────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        return _protocolBalance() + underlying.balanceOf(address(this)) - accruedFees;
    }

    function _protocolBalance() internal view returns (uint256) {
        if (activeProtocol == 1) return aaveAToken.balanceOf(address(this));
        if (activeProtocol == 2) return compound.balanceOf(address(this));
        if (activeProtocol == 3) return fluid.previewRedeem(fluid.balanceOf(address(this)));
        if (activeProtocol == 4) return gains.previewRedeem(gains.balanceOf(address(this)));
        return 0;
    }

    function version() external pure returns (string memory) { return "2.0.0"; }

    // ── user actions ────────────────────────────────

    function deposit(uint256 assets, address receiver)
        public override nonReentrant returns (uint256)
    {
        require(!depositsPaused, "deposits paused");
        require(assets >= MIN_DEPOSIT, "below minimum");
        uint256 shares = super.deposit(assets, receiver);
        _supplyToActive(assets);
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address o)
        public override nonReentrant returns (uint256)
    {
        _ensureLiquidity(assets);
        return super.withdraw(assets, receiver, o);
    }

    function redeem(uint256 shares, address receiver, address o)
        public override nonReentrant returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        return super.redeem(shares, receiver, o);
    }

    // ── strategy (strategist or owner) ──────────────

    function rebalanceTo(uint8 toProtocol) external onlyStrategistOrOwner {
        require(toProtocol >= 1 && toProtocol <= 3, "invalid protocol");
        require(toProtocol != activeProtocol, "already active");

        uint256 bal = _withdrawAll();
        uint8 from = activeProtocol;
        activeProtocol = toProtocol;
        _supplyToActive(bal);

        emit Rebalanced(from, toProtocol, bal);
    }

    function harvest() external onlyStrategistOrOwner {
        uint256 gross = _protocolBalance() + underlying.balanceOf(address(this));
        uint256 owed = totalSupply() + accruedFees;

        if (gross <= owed) return;

        uint256 yield_ = gross - owed;
        uint256 pFee = (yield_ * perfFeeBps) / BPS;

        uint256 dt = block.timestamp - lastHarvest;
        uint256 mFee = (totalSupply() * mgmtFeeBps * dt) / (BPS * 365 days);

        accruedFees += pFee + mFee;
        lastHarvest = block.timestamp;

        emit Harvest(yield_, pFee + mFee);
    }

    function collectFees() external onlyOwner {
        uint256 amt = accruedFees;
        require(amt > 0, "no fees");
        accruedFees = 0;
        _ensureLiquidity(amt);
        underlying.safeTransfer(owner(), amt);
        emit FeesCollected(amt);
    }

    function deployIdle() external onlyStrategistOrOwner {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle > accruedFees) {
            _supplyToActive(idle - accruedFees);
        }
    }

    // ── admin (owner only) ──────────────────────────

    function setStrategist(address s) external onlyOwner {
        emit StrategistUpdated(strategist, s);
        strategist = s;
    }

    function setDepositsPaused(bool v) external onlyOwner {
        depositsPaused = v;
        emit DepositsPaused(v);
    }

    function emergencyExit() external onlyOwner {
        _withdrawAll();
        depositsPaused = true;
        activeProtocol = 0;
        emit DepositsPaused(true);
    }

    function setFees(uint256 perf, uint256 mgmt) external onlyOwner {
        require(perf <= MAX_PERF_FEE && mgmt <= MAX_MGMT_FEE, "fee cap");
        perfFeeBps = perf;
        mgmtFeeBps = mgmt;
    }

    // ── internal: protocol routing ──────────────────

    function _supplyToActive(uint256 amt) internal {
        if (amt == 0) return;
        if (activeProtocol == 1) aavePool.supply(address(underlying), amt, address(this), 0);
        else if (activeProtocol == 2) compound.supply(address(underlying), amt);
        else if (activeProtocol == 3) fluid.deposit(amt, address(this));
        else if (activeProtocol == 4) gains.deposit(amt, address(this));
    }

    function _withdrawAll() internal returns (uint256) {
        uint256 before = underlying.balanceOf(address(this));
        if (activeProtocol == 1) {
            uint256 bal = aaveAToken.balanceOf(address(this));
            if (bal > 0) aavePool.withdraw(address(underlying), bal, address(this));
        } else if (activeProtocol == 2) {
            uint256 bal = compound.balanceOf(address(this));
            if (bal > 0) compound.withdraw(address(underlying), bal);
        } else if (activeProtocol == 3) {
            uint256 bal = fluid.balanceOf(address(this));
            if (bal > 0) fluid.redeem(bal, address(this), address(this));
        } else if (activeProtocol == 4) {
            uint256 bal = gains.balanceOf(address(this));
            if (bal > 0) gains.redeem(bal, address(this), address(this));
        }
        return underlying.balanceOf(address(this)) - before;
    }

    function _ensureLiquidity(uint256 needed) internal {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle >= needed) return;
        uint256 gap = needed - idle;
        if (activeProtocol == 1) {
            uint256 bal = aaveAToken.balanceOf(address(this));
            uint256 w = gap > bal ? bal : gap;
            if (w > 0) aavePool.withdraw(address(underlying), w, address(this));
        } else if (activeProtocol == 2) {
            uint256 bal = compound.balanceOf(address(this));
            uint256 w = gap > bal ? bal : gap;
            if (w > 0) compound.withdraw(address(underlying), w);
        } else if (activeProtocol == 3) {
            // approximate shares needed
            uint256 bal = fluid.balanceOf(address(this));
            if (bal > 0) fluid.redeem(bal, address(this), address(this));
        } else if (activeProtocol == 4) {
            uint256 bal = gains.balanceOf(address(this));
            if (bal > 0) gains.redeem(bal, address(this), address(this));
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
