// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IScaledBalance {
    function balanceOf(address user) external view returns (uint256);
}

/// @title AlphaPrimer Yield Vault
/// @notice UUPS-upgradeable ERC-4626 vault routing USDC into Aave V3
/// @dev Owner is expected to be a TimelockController behind a multi-sig
contract AlphaPrimerVault is
    ERC4626Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    IPool public pool;
    IScaledBalance public aToken;
    IERC20 public underlying;

    uint256 public perfFeeBps;
    uint256 public mgmtFeeBps;
    uint256 public constant MAX_PERF_FEE = 2000;
    uint256 public constant MAX_MGMT_FEE = 200;
    uint256 public constant BPS = 10_000;

    uint256 public lastHarvest;
    uint256 public accruedFees;
    bool public depositsPaused;

    event Harvest(uint256 yield, uint256 fee);
    event FeesCollected(uint256 amount);
    event DepositsPaused(bool state);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address pool_,
        address aToken_,
        address owner_,
        uint256 perfFee_,
        uint256 mgmtFee_
    ) external initializer {
        __ERC4626_init(IERC20(asset_));
        __ERC20_init("AlphaPrimer USDC Vault", "apUSDC");
        __Ownable_init(owner_);
        // UUPSUpgradeable and ReentrancyGuardTransient need no init in v5

        underlying = IERC20(asset_);
        pool = IPool(pool_);
        aToken = IScaledBalance(aToken_);
        perfFeeBps = perfFee_;
        mgmtFeeBps = mgmtFee_;
        lastHarvest = block.timestamp;

        underlying.approve(pool_, type(uint256).max);
    }

    // ── views ──────────────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this))
             + underlying.balanceOf(address(this))
             - accruedFees;
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // ── user actions ───────────────────────────────────────

    uint256 public constant MIN_DEPOSIT = 1e6; // 1 USDC minimum

    function deposit(uint256 assets, address receiver)
        public override nonReentrant returns (uint256)
    {
        require(!depositsPaused, "deposits paused");
        require(assets >= MIN_DEPOSIT, "below minimum");
        uint256 shares = super.deposit(assets, receiver);
        _supply(assets);
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

    // ── strategy management (owner / timelock) ─────────────

    function harvest() external onlyOwner {
        uint256 gross = aToken.balanceOf(address(this))
                      + underlying.balanceOf(address(this));
        uint256 owed = totalSupply() + accruedFees; // what we owe users + pending fees

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

    function rebalance() external onlyOwner {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle > accruedFees) {
            _supply(idle - accruedFees);
        }
    }

    // ── safety ──────────────────────────────────────────────

    function setDepositsPaused(bool v) external onlyOwner {
        depositsPaused = v;
        emit DepositsPaused(v);
    }

    function emergencyExit() external onlyOwner {
        pool.withdraw(address(underlying), type(uint256).max, address(this));
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    function setFees(uint256 perf, uint256 mgmt) external onlyOwner {
        require(perf <= MAX_PERF_FEE && mgmt <= MAX_MGMT_FEE, "fee cap");
        perfFeeBps = perf;
        mgmtFeeBps = mgmt;
    }

    // ── internal ────────────────────────────────────────────

    function _supply(uint256 amt) internal {
        if (amt > 0) pool.supply(address(underlying), amt, address(this), 0);
    }

    function _ensureLiquidity(uint256 needed) internal {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle < needed) {
            uint256 gap = needed - idle;
            uint256 aaveBal = aToken.balanceOf(address(this));
            uint256 toWithdraw = gap > aaveBal ? aaveBal : gap;
            if (toWithdraw > 0) {
                pool.withdraw(address(underlying), toWithdraw, address(this));
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
