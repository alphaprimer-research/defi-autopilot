// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Comprehensive v3.4 verification: guardian, view accuracy,
///         mgmt fee in flat markets, approve revocation, rebalance slippage.
contract V34Verification is Test {
    AlphaPrimerVault vault;
    IERC20 usdc;

    address constant USDC     = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE     = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AUSDC    = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address constant COMPOUND = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address constant FLUID    = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address constant WHALE    = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address owner = makeAddr("owner");
    address strategist = makeAddr("strategist");
    address guardian_ = makeAddr("guardian");
    address alice = makeAddr("alice");
    address eve = makeAddr("eve");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");

        AlphaPrimerVault impl = new AlphaPrimerVault();
        bytes memory initData = abi.encodeCall(
            AlphaPrimerVault.initialize,
            (USDC, owner, strategist, AAVE, AUSDC, COMPOUND, FLUID, 1000, 100)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = AlphaPrimerVault(address(proxy));
        usdc = IERC20(USDC);

        vm.prank(owner);
        vault.setGuardian(guardian_);

        vm.startPrank(WHALE);
        usdc.transfer(alice, 100_000e6);
        usdc.transfer(eve, 100_000e6);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amt) internal {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _rebalanceTo(uint8 to) internal {
        vault.rebalanceTo(to, vault.totalAssets() * 99 / 100);
    }

    // ── Guardian tests ──────────────────────────────

    function test_guardian_can_emergency_exit() public {
        _deposit(alice, 10_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();
        assertTrue(vault.depositsPaused());
        assertEq(vault.activeProtocol(), 0);
    }

    function test_guardian_can_pause_deposits() public {
        vm.prank(guardian_);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());
    }

    function test_guardian_cannot_harvest() public {
        _deposit(alice, 1_000e6);
        vm.prank(guardian_);
        vm.expectRevert("not authorized");
        vault.harvest();
    }

    function test_guardian_cannot_upgrade() public {
        AlphaPrimerVault newImpl = new AlphaPrimerVault();
        vm.prank(guardian_);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_guardian_cannot_set_fees() public {
        vm.prank(guardian_);
        vm.expectRevert();
        vault.setFees(500, 50);
    }

    function test_attacker_cannot_use_guardian_functions() public {
        vm.prank(attacker);
        vm.expectRevert("not guardian");
        vault.emergencyExit();
    }

    // ── maxWithdraw accuracy ───────────────────────

    function test_withdraw_maxWithdraw_does_not_revert() public {
        _deposit(alice, 10_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 max = vault.maxWithdraw(alice);
        assertGt(max, 0, "maxWithdraw should be positive");
        vm.prank(alice);
        vault.withdraw(max, alice, alice);
        // no revert = L-07 fixed. dust shares may remain (ERC-4626 rounding).
    }

    // ── previewRedeem accuracy ─────────────────────

    function test_previewRedeem_not_inflated() public {
        _deposit(alice, 10_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 shares = vault.balanceOf(alice);
        uint256 preview = vault.previewRedeem(shares);

        vm.prank(alice);
        uint256 actual = vault.redeem(shares, alice, alice);

        assertLe(preview, actual + 1, "preview inflated beyond actual");
    }

    // ── mgmt fee accrues even without yield ─────────

    function test_mgmt_fee_accrues_in_flat_market() public {
        _deposit(alice, 10_000e6);
        uint256 hwmBefore = vault.highWaterMark();

        // simulate flat market: no yield, just time passing
        // (Aave will give tiny yield, but mgmt should still work)
        vm.warp(block.timestamp + 365 days);

        vm.prank(strategist);
        vault.harvest();

        uint256 fees = vault.accruedFees();
        // mgmt fee = 10000 * 100 / 10000 * 1 year = 100 USDC = 100_000_000 wei
        // with Aave yield there will also be perf fee
        assertGt(fees, 90_000_000, "mgmt fee too low - should be ~$100");
    }

    // ── emergencyExit revokes approvals ──────────────

    function test_emergency_exit_revokes_approvals() public {
        _deposit(alice, 5_000e6);

        vm.prank(guardian_);
        vault.emergencyExit();

        assertEq(usdc.allowance(address(vault), address(vault.aavePool())), 0);
        assertEq(usdc.allowance(address(vault), address(vault.compound())), 0);
        assertEq(usdc.allowance(address(vault), address(vault.fluid())), 0);
    }

    // ── rebalanceTo settles fees ─────────────────────

    function test_rebalanceTo_settles_fees_first() public {
        _deposit(alice, 10_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 feesBefore = vault.accruedFees();

        vm.startPrank(strategist);
        _rebalanceTo(2);
        vm.stopPrank();

        uint256 feesAfter = vault.accruedFees();
        assertGt(feesAfter, feesBefore, "rebalanceTo did not settle fees");
    }

    // ── rebalanceTo minReceived protects against slippage ──

    function test_rebalanceTo_reverts_on_slippage() public {
        _deposit(alice, 10_000e6);

        vm.prank(strategist);
        vm.expectRevert("rebalance slippage");
        vault.rebalanceTo(2, type(uint256).max);
    }

    // ── Fluid 3-arg deposit works ────────────────────

    function test_fluid_3arg_deposit() public {
        _deposit(alice, 5_000e6);

        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank();

        assertEq(vault.activeProtocol(), 3);
        assertGt(vault.totalAssets(), 4_900e6);
    }

    // ── harvest loop still no compounding ────────────

    function test_harvest_no_compounding_v34() public {
        _deposit(alice, 10_000e6);
        vm.warp(block.timestamp + 30 days);

        vm.startPrank(strategist);
        vault.harvest();
        uint256 feesFirst = vault.accruedFees();

        for (uint256 i = 0; i < 20; i++) {
            vault.harvest();
        }
        uint256 feesLoop = vault.accruedFees();
        vm.stopPrank();

        assertEq(feesLoop, feesFirst, "fees compounded on loop");
    }

    // ── full drain clean state ───────────────────────

    function test_full_drain_v34() public {
        _deposit(alice, 10_000e6);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.totalSupply(), 0);
    }

    function test_version() public view {
        assertEq(vault.version(), "3.5.0");
    }
}
