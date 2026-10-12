// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

interface IScaledBalance {
    function balanceOf(address user) external view returns (uint256);
}

/// @title AlphaPrimer Multi-Strategy Yield Vault v3.2
/// @notice Routes USDC to the highest-yielding protocol among
///         Aave V3, Compound V3, and Fluid on Arbitrum.
/// @dev Owner = TimelockController behind 4/5 multi-sig.
///      Strategist = bot wallet with limited rebalance-only access.
contract AlphaPrimerVault is
    ERC4626Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

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
    uint256 public highWaterMark;
    bool public depositsPaused;

    uint8 public activeProtocol; // 0=idle, 1=aave, 2=compound, 3=fluid

    IAavePool public aavePool;
    IScaledBalance public aaveAToken;
    IComet public compound;
    IFluidVault public fluid;

    /// @dev storage gap for future upgrades
    uint256[40] private __gap;

    event Harvest(uint256 yield, uint256 fee);
    event FeesCollected(uint256 amount);
    event DepositsPaused(bool state);
    event Rebalanced(uint8 fromProtocol, uint8 toProtocol, uint256 amount);
    event StrategistUpdated(address indexed prev, address indexed next);
    event FeesUpdated(uint256 perfFeeBps, uint256 mgmtFeeBps);

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

        require(perfFee_ <= MAX_PERF_FEE && mgmtFee_ <= MAX_MGMT_FEE, "fee cap");
        require(owner_ != address(0) && asset_ != address(0), "zero addr");
        require(strategist_ != address(0), "zero strategist");
        require(aavePool_ != address(0) && aaveAToken_ != address(0), "zero aave");
        require(compound_ != address(0) && fluid_ != address(0), "zero protocol");
        perfFeeBps = perfFee_;
        mgmtFeeBps = mgmtFee_;
        lastHarvest = block.timestamp;
        highWaterMark = 0;
        activeProtocol = 1;

        underlying.approve(aavePool_, type(uint256).max);
        underlying.approve(compound_, type(uint256).max);
        underlying.approve(fluid_, type(uint256).max);
    }

    // ── views ───────────────────────────────────────

    /// @dev offset 6 per Morpho recommendation — prevents donation inflation
    function _decimalsOffset() internal pure override returns (uint8) { return 6; }

    function totalAssets() public view override returns (uint256) {
        uint256 gross = _protocolBalance() + underlying.balanceOf(address(this));
        return gross > accruedFees ? gross - accruedFees : 0;
    }

    function _protocolBalance() internal view returns (uint256) {
        if (activeProtocol == 1) return aaveAToken.balanceOf(address(this));
        if (activeProtocol == 2) return compound.balanceOf(address(this));
        if (activeProtocol == 3) return fluid.previewRedeem(fluid.balanceOf(address(this)));
        return 0;
    }

    function version() external pure returns (string memory) { return "3.2.0"; }

    // ── user actions ────────────────────────────────

    function maxDeposit(address) public view override returns (uint256) {
        return depositsPaused ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return depositsPaused ? 0 : type(uint256).max;
    }

    function deposit(uint256 assets, address receiver)
        public override nonReentrant returns (uint256)
    {
        require(!depositsPaused, "deposits paused");
        require(assets >= MIN_DEPOSIT, "below minimum");
        if (lastHarvest < block.timestamp) lastHarvest = block.timestamp;
        uint256 shares = super.deposit(assets, receiver);
        require(shares > 0, "zero shares");
        _supplyToActive(assets);
        highWaterMark += assets;
        return shares;
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant returns (uint256)
    {
        require(!depositsPaused, "deposits paused");
        uint256 assets = previewMint(shares);
        require(assets >= MIN_DEPOSIT, "below minimum");
        if (lastHarvest < block.timestamp) lastHarvest = block.timestamp;
        uint256 actualAssets = super.mint(shares, receiver);
        require(actualAssets > 0, "zero assets");
        _supplyToActive(actualAssets);
        highWaterMark += actualAssets;
        return actualAssets;
    }

    function withdraw(uint256 assets, address receiver, address o)
        public override nonReentrant returns (uint256)
    {
        _ensureLiquidity(assets);
        uint256 ta = totalAssets();
        if (ta > 0) highWaterMark = highWaterMark * (ta - assets) / ta;
        return super.withdraw(assets, receiver, o);
    }

    function redeem(uint256 shares, address receiver, address o)
        public override nonReentrant returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        uint256 ta = totalAssets();
        if (ta > 0) highWaterMark = highWaterMark * (ta - assets) / ta;
        return super.redeem(shares, receiver, o);
    }

    // ── strategy (strategist or owner) ──────────────

    function rebalanceTo(uint8 toProtocol) external onlyStrategistOrOwner nonReentrant {
        require(toProtocol >= 1 && toProtocol <= 3, "invalid protocol");
        require(toProtocol != activeProtocol, "already active");

        uint256 bal = _withdrawAll();
        uint8 from = activeProtocol;
        activeProtocol = toProtocol;
        _supplyToActive(bal);

        emit Rebalanced(from, toProtocol, bal);
    }

    function harvest() public onlyStrategistOrOwner nonReentrant {
        uint256 nav = totalAssets();

        // always refresh clock, even on early return
        uint256 dt = block.timestamp - lastHarvest;
        lastHarvest = block.timestamp;

        if (nav <= highWaterMark) return;

        uint256 yield_ = nav - highWaterMark;
        uint256 pFee = (yield_ * perfFeeBps) / BPS;

        // mgmt fee only on capital that was present for dt
        // use highWaterMark (prior NAV) as the base, not current nav
        uint256 mFee = (highWaterMark * mgmtFeeBps * dt) / (BPS * 365 days);

        uint256 take = pFee + mFee;
        if (take > nav) take = nav;
        accruedFees += take;
        highWaterMark = totalAssets();

        emit Harvest(yield_, take);
    }

    function collectFees() external onlyOwner nonReentrant {
        uint256 amt = accruedFees;
        require(amt > 0, "no fees");
        accruedFees = 0;
        _ensureLiquidity(amt);
        underlying.safeTransfer(owner(), amt);
        emit FeesCollected(amt);
    }

    function deployIdle() external onlyStrategistOrOwner nonReentrant {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle > accruedFees) {
            _supplyToActive(idle - accruedFees);
        }
    }

    // ── admin (owner only) ──────────────────────────

    function setStrategist(address s) external onlyOwner {
        require(s != address(0), "zero strategist");
        emit StrategistUpdated(strategist, s);
        strategist = s;
    }

    function setDepositsPaused(bool v) external onlyOwner {
        depositsPaused = v;
        emit DepositsPaused(v);
    }

    function emergencyExit() external onlyOwner nonReentrant {
        _withdrawAll();
        depositsPaused = true;
        activeProtocol = 0;
        emit DepositsPaused(true);
    }

    function setFees(uint256 perf, uint256 mgmt) external onlyOwner {
        require(perf <= MAX_PERF_FEE && mgmt <= MAX_MGMT_FEE, "fee cap");
        if (totalSupply() > 0) harvest();
        perfFeeBps = perf;
        mgmtFeeBps = mgmt;
        emit FeesUpdated(perf, mgmt);
    }

    // ── internal: protocol routing ──────────────────

    function _supplyToActive(uint256 amt) internal {
        if (amt == 0) return;
        if (activeProtocol == 1) aavePool.supply(address(underlying), amt, address(this), 0);
        else if (activeProtocol == 2) compound.supply(address(underlying), amt);
        else if (activeProtocol == 3) fluid.deposit(amt, address(this));
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
            uint256 bal = fluid.balanceOf(address(this));
            if (bal > 0) {
                uint256 redeemable = fluid.previewRedeem(bal);
                if (redeemable <= gap) {
                    fluid.redeem(bal, address(this), address(this));
                } else {
                    uint256 sharesToRedeem = bal * gap / redeemable;
                    if (sharesToRedeem > 0) fluid.redeem(sharesToRedeem, address(this), address(this));
                }
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
