// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Edge case tests against the DEPLOYED vault on Arbitrum mainnet.
contract MainnetEdgeCases is Test {
    AlphaPrimerVault vault;
    IERC20 usdc;

    address constant VAULT_PROXY = 0x87Ef5c25203886b1026ad907E7f84fBAABdF1fa9;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address owner;
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
        vault = AlphaPrimerVault(VAULT_PROXY);
        usdc = IERC20(USDC);
        owner = vault.owner();

        vm.startPrank(WHALE);
        usdc.transfer(attacker, 100_000e6);
        usdc.transfer(victim, 50_000e6);
        vm.stopPrank();
    }

    // harvest loop must NOT compound fees
    function test_harvest_loop_no_fee_compounding() public {
        vm.startPrank(owner);
        vault.harvest();
        uint256 feesAfterFirst = vault.accruedFees();

        // call harvest 20 more times — fees must NOT grow
        for (uint256 i = 0; i < 20; i++) {
            vault.harvest();
        }
        uint256 feesAfterLoop = vault.accruedFees();
        vm.stopPrank();

        assertEq(feesAfterLoop, feesAfterFirst, "fees grew on repeated harvest");
    }

    // donation to vault must not steal next depositor's funds
    function test_donation_does_not_steal_next_deposit() public {
        // attacker donates large amount directly to vault
        vm.prank(WHALE);
        usdc.transfer(VAULT_PROXY, 50_000e6);

        // victim deposits — must get shares > 0
        vm.startPrank(victim);
        usdc.approve(VAULT_PROXY, 10_000e6);
        uint256 shares = vault.deposit(10_000e6, victim);
        vm.stopPrank();

        assertGt(shares, 0, "inflation: victim got 0 shares after donation");

        // victim redeems — must get back meaningful amount
        vm.startPrank(victim);
        uint256 redeemed = vault.redeem(shares, victim, victim);
        vm.stopPrank();

        assertGt(redeemed, 9_000e6, "inflation: victim lost >10% on deposit+redeem");
    }

    // two users deposit, proportional shares
    function test_multi_user_proportional() public {
        vm.startPrank(attacker);
        usdc.approve(VAULT_PROXY, 20_000e6);
        uint256 sharesA = vault.deposit(20_000e6, attacker);
        vm.stopPrank();

        vm.startPrank(victim);
        usdc.approve(VAULT_PROXY, 10_000e6);
        uint256 sharesV = vault.deposit(10_000e6, victim);
        vm.stopPrank();

        // attacker deposited 2x victim → should have ~2x shares
        // (not exact due to existing vault state, but roughly)
        assertGt(sharesA, sharesV, "multi-user: larger depositor has fewer shares");

        // both redeem — each gets back ~what they put in
        vm.prank(attacker);
        uint256 redeemedA = vault.redeem(sharesA, attacker, attacker);

        vm.prank(victim);
        uint256 redeemedV = vault.redeem(sharesV, victim, victim);

        assertGt(redeemedA, 19_000e6, "multi-user: attacker lost >5%");
        assertGt(redeemedV, 9_000e6, "multi-user: victim lost >10%");
    }

    // last user redeems everything, vault state clean
    function test_full_drain_vault_clean() public {
        // deposit fresh
        vm.startPrank(attacker);
        usdc.approve(VAULT_PROXY, 5_000e6);
        vault.deposit(5_000e6, attacker);
        vm.stopPrank();

        // get all existing shares (owner + attacker)
        uint256 ownerShares = vault.balanceOf(owner);
        uint256 attackerShares = vault.balanceOf(attacker);

        // owner redeems all
        if (ownerShares > 0) {
            vm.prank(owner);
            vault.redeem(ownerShares, owner, owner);
        }

        // attacker redeems all
        vm.prank(attacker);
        vault.redeem(attackerShares, attacker, attacker);

        // vault should be clean
        assertEq(vault.totalSupply(), 0, "full drain: supply not zero");
    }

    // attacker cannot harvest, rebalance, or collect
    function test_attacker_cannot_operate() public {
        vm.startPrank(attacker);

        vm.expectRevert("not authorized");
        vault.harvest();

        vm.expectRevert("not authorized");
        vault.rebalanceTo(2, 0);

        vm.expectRevert();
        vault.collectFees();

        vm.expectRevert();
        vault.emergencyExit();

        vm.stopPrank();
    }
}
