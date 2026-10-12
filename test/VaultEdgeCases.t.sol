// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultEdgeCases is Test {
    AlphaPrimerVault vault;
    IERC20 usdc;

    address constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant POOL  = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AUSDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address constant WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address eve   = makeAddr("eve");

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");

        AlphaPrimerVault impl = new AlphaPrimerVault();
        bytes memory initData = abi.encodeCall(
            AlphaPrimerVault.initialize,
            (USDC, POOL, AUSDC, owner, 1000, 100)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = AlphaPrimerVault(address(proxy));
        usdc = IERC20(USDC);

        vm.startPrank(WHALE);
        usdc.transfer(alice, 50_000e6);
        usdc.transfer(bob, 20_000e6);
        vm.stopPrank();
    }

    // ── zero / dust amounts ────────────────────────

    function test_deposit_below_minimum_reverts() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert("below minimum");
        vault.deposit(0, alice);

        vm.expectRevert("below minimum");
        vault.deposit(999_999, alice); // 0.999999 USDC < 1 USDC minimum
        vm.stopPrank();
    }

    function test_deposit_dust_1_usdc() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1e6);
        uint256 shares = vault.deposit(1e6, alice);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    // ── full withdrawal drains vault ───────────────

    function test_single_user_full_redeem() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        uint256 shares = vault.deposit(10_000e6, alice);

        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
    }

    // ── multi-user simultaneous withdraw ───────────

    function test_two_users_both_redeem_all() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        uint256 aShares = vault.deposit(10_000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 5_000e6);
        uint256 bShares = vault.deposit(5_000e6, bob);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(aShares, alice, alice);

        vm.prank(bob);
        vault.redeem(bShares, bob, bob);

        assertEq(vault.totalSupply(), 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 50_000e6, 100);
        assertApproxEqAbs(usdc.balanceOf(bob), 20_000e6, 100);
    }

    // ── non-depositor cannot withdraw ──────────────

    function test_non_depositor_cannot_redeem() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert();
        vault.redeem(1, eve, eve);
        vm.stopPrank();
    }

    // ── deposits paused ────────────────────────────

    function test_deposit_when_paused_reverts() public {
        vm.prank(owner);
        vault.setDepositsPaused(true);

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert("deposits paused");
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_withdraw_works_when_paused() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.setDepositsPaused(true);

        // withdraw should still work
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ── large deposit ──────────────────────────────

    function test_large_deposit_50k() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 50_000e6);
        uint256 shares = vault.deposit(50_000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertGt(vault.totalAssets(), 49_999e6);
    }

    // ── owner cannot steal user funds ──────────────

    function test_owner_cannot_transfer_user_funds() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();

        // owner tries to redeem alice's shares
        vm.startPrank(owner);
        vm.expectRevert();
        vault.redeem(1, owner, alice);
        vm.stopPrank();
    }

    // ── fee collection ─────────────────────────────

    function test_collect_fees_only_takes_accrued() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 180 days);

        uint256 aliceSharesBefore = vault.balanceOf(alice);

        vm.startPrank(owner);
        vault.harvest();
        uint256 fees = vault.accruedFees();
        vault.collectFees();
        vm.stopPrank();

        // alice shares unchanged
        assertEq(vault.balanceOf(alice), aliceSharesBefore);
        // owner received fees
        assertGt(usdc.balanceOf(owner), 0);
        assertEq(usdc.balanceOf(owner), fees);
    }

    // ── ERC4626 inflation attack protection ────────

    function test_inflation_attack_mitigated() public {
        // minimum deposit prevents 1 wei attack
        vm.startPrank(alice);
        usdc.approve(address(vault), 1);
        vm.expectRevert("below minimum");
        vault.deposit(1, alice);
        vm.stopPrank();

        // attacker must deposit at least 1 USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 1e6);
        vault.deposit(1e6, alice);
        vm.stopPrank();

        // attacker donates large amount directly to vault
        vm.prank(WHALE);
        usdc.transfer(address(vault), 10_000e6);

        // victim deposits — should still get shares
        vm.startPrank(bob);
        usdc.approve(address(vault), 5_000e6);
        uint256 shares = vault.deposit(5_000e6, bob);
        vm.stopPrank();

        assertGt(shares, 0, "victim should get shares");
    }

    // ── rebalance idle funds ───────────────────────

    function test_rebalance_deploys_idle() public {
        // send USDC directly to vault (simulates stuck idle)
        vm.prank(WHALE);
        usdc.transfer(address(vault), 1_000e6);

        uint256 idleBefore = usdc.balanceOf(address(vault));
        assertGt(idleBefore, 0);

        vm.prank(owner);
        vault.rebalance();

        uint256 idleAfter = usdc.balanceOf(address(vault));
        assertLt(idleAfter, idleBefore, "idle should decrease");
    }
}
