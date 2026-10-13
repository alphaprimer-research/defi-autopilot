// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RebalanceTest is Test {
    AlphaPrimerVault vault;
    IERC20 usdc;

    address constant USDC     = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE     = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AUSDC    = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address constant COMPOUND = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address constant FLUID    = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    address constant GAINS    = 0xd3443ee1e91aF28e5FB858Fbd0D72A63bA8046E0;
    address constant WHALE    = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address owner = makeAddr("owner");
    address strategist = makeAddr("strategist");
    address alice = makeAddr("alice");

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

        vm.prank(WHALE);
        usdc.transfer(alice, 10_000e6);
    }

    function _deposit(uint256 amt) internal {
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();
    }

    function _rebalanceTo(uint8 to) internal {
        vault.rebalanceTo(to, vault.totalAssets() * 99 / 100);
    }

    // ── Aave (protocol 1) — already tested ─────────

    function test_starts_on_aave() public {
        assertEq(vault.activeProtocol(), 1);
    }

    function test_aave_deposit_and_yield() public {
        _deposit(5_000e6);
        uint256 before = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        assertGt(vault.totalAssets(), before);
    }

    // ── Compound (protocol 2) ──────────────────────

    function test_rebalance_to_compound() public {
        _deposit(5_000e6);
        uint256 assetsBefore = vault.totalAssets();

        vm.startPrank(strategist);
        _rebalanceTo(2);
        vm.stopPrank();

        assertEq(vault.activeProtocol(), 2);
        assertApproxEqRel(vault.totalAssets(), assetsBefore, 0.01e18);
    }

    function test_compound_earns_yield() public {
        _deposit(5_000e6);
        vm.startPrank(strategist);
        _rebalanceTo(2);
        vm.stopPrank();

        uint256 before = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        assertGt(vault.totalAssets(), before, "compound should earn yield");
    }

    function test_withdraw_from_compound() public {
        _deposit(5_000e6);
        vm.startPrank(strategist);
        _rebalanceTo(2);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 10_000e6, 100);
    }

    // ── Fluid (protocol 3) ─────────────────────────

    function test_rebalance_to_fluid() public {
        _deposit(5_000e6);
        uint256 assetsBefore = vault.totalAssets();

        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank();

        assertEq(vault.activeProtocol(), 3);
        assertApproxEqRel(vault.totalAssets(), assetsBefore, 0.02e18);
    }

    function test_fluid_earns_yield() public {
        _deposit(5_000e6);
        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank();

        uint256 before = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        assertGt(vault.totalAssets(), before, "fluid should earn yield");
    }

    function test_withdraw_from_fluid() public {
        _deposit(5_000e6);
        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
        assertApproxEqAbs(usdc.balanceOf(alice), 10_000e6, 100);
    }

    // ── Cross-protocol rebalance ───────────────────

    function test_aave_to_compound_to_fluid() public {
        _deposit(5_000e6);

        vm.startPrank(strategist);
        _rebalanceTo(2);
        vm.stopPrank(); // aave → compound
        assertEq(vault.activeProtocol(), 2);

        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank(); // compound → fluid
        assertEq(vault.activeProtocol(), 3);

        assertGt(vault.totalAssets(), 4_900e6);
    }

    function test_full_rotation_all_protocols() public {
        _deposit(5_000e6);
        uint256 initial = vault.totalAssets();

        vm.startPrank(strategist);
        _rebalanceTo(2);
        vm.stopPrank(); // aave → compound
        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank(); // compound → fluid
        vm.startPrank(strategist);
        _rebalanceTo(1);
        vm.stopPrank(); // fluid → back to aave

        assertApproxEqRel(vault.totalAssets(), initial, 0.05e18);
    }

    // ── Access control ─────────────────────────────

    function test_only_strategist_can_rebalance() public {
        _deposit(1_000e6);
        uint256 min = vault.totalAssets() * 99 / 100;
        vm.prank(alice);
        vm.expectRevert("not authorized");
        vault.rebalanceTo(2, min);
    }

    function test_owner_can_also_rebalance() public {
        _deposit(1_000e6);

        vm.startPrank(owner);
        _rebalanceTo(2);
        vm.stopPrank();
        assertEq(vault.activeProtocol(), 2);
    }

    function test_cannot_rebalance_to_same() public {
        _deposit(1_000e6);
        uint256 min = vault.totalAssets() * 99 / 100;
        vm.prank(strategist);
        vm.expectRevert("already active");
        vault.rebalanceTo(1, min);
    }

    function test_cannot_rebalance_to_invalid() public {
        _deposit(1_000e6);

        vm.prank(strategist);
        vm.expectRevert("invalid protocol");
        vault.rebalanceTo(4, 0);
    }
}
