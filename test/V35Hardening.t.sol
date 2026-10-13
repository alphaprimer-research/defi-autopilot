// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract V35Hardening is Test {
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

        vm.prank(WHALE);
        usdc.transfer(alice, 100_000e6);
    }

    function _deposit(uint256 amt) internal {
        vm.startPrank(alice);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, alice);
        vm.stopPrank();
    }

    // ── minReceived cannot be 0 ─────────────────────

    function test_rebalanceTo_rejects_zero_minReceived() public {
        _deposit(5_000e6);
        vm.prank(strategist);
        vm.expectRevert("min too low");
        vault.rebalanceTo(2, 0);
    }

    function test_rebalanceTo_rejects_low_minReceived() public {
        _deposit(5_000e6);
        uint256 assets = vault.totalAssets();
        uint256 tooLow = assets * 97 / 100;
        vm.prank(strategist);
        vm.expectRevert("min too low");
        vault.rebalanceTo(2, tooLow);
    }

    function test_rebalanceTo_accepts_99pct_minReceived() public {
        _deposit(5_000e6);
        uint256 assets = vault.totalAssets();
        uint256 okMin = assets * 9800 / 10000;
        vm.prank(strategist);
        vault.rebalanceTo(2, okMin);
        assertEq(vault.activeProtocol(), 2);
    }

    // ── setGuardian(0) blocked ──────────────────────

    function test_setGuardian_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert("zero guardian");
        vault.setGuardian(address(0));
    }

    function test_setGuardian_nonzero_works() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        vault.setGuardian(newGuardian);
        assertEq(vault.guardian(), newGuardian);
    }

    // ── emergencyExit + reactivate full cycle ───────

    function test_emergency_then_reactivate() public {
        _deposit(10_000e6);
        uint256 assetsBefore = vault.totalAssets();

        // emergency exit
        vm.prank(guardian_);
        vault.emergencyExit();

        assertTrue(vault.depositsPaused());
        assertEq(vault.activeProtocol(), 0);
        assertEq(usdc.allowance(address(vault), address(vault.aavePool())), 0);

        // reactivate to Aave
        vm.prank(owner);
        vault.reactivate(1);

        assertFalse(vault.depositsPaused());
        assertEq(vault.activeProtocol(), 1);
        assertGt(usdc.allowance(address(vault), address(vault.aavePool())), 0);
        assertApproxEqRel(vault.totalAssets(), assetsBefore, 0.01e18);
    }

    function test_reactivate_to_compound() public {
        _deposit(5_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();

        vm.prank(owner);
        vault.reactivate(2);

        assertEq(vault.activeProtocol(), 2);
        assertFalse(vault.depositsPaused());
    }

    function test_reactivate_to_fluid() public {
        _deposit(5_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();

        vm.prank(owner);
        vault.reactivate(3);

        assertEq(vault.activeProtocol(), 3);
        assertFalse(vault.depositsPaused());
    }

    function test_reactivate_only_owner() public {
        _deposit(1_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();

        vm.prank(strategist);
        vm.expectRevert();
        vault.reactivate(1);

        vm.prank(guardian_);
        vm.expectRevert();
        vault.reactivate(1);
    }

    function test_reactivate_invalid_protocol_reverts() public {
        _deposit(1_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();

        vm.prank(owner);
        vm.expectRevert("invalid protocol");
        vault.reactivate(0);

        vm.prank(owner);
        vm.expectRevert("invalid protocol");
        vault.reactivate(4);
    }

    function test_deposit_works_after_reactivate() public {
        _deposit(5_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();

        vm.prank(owner);
        vault.reactivate(1);

        // new deposit should work
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertGt(vault.totalAssets(), 5_900e6);
    }

    function test_withdraw_works_after_reactivate() public {
        _deposit(5_000e6);
        vm.prank(guardian_);
        vault.emergencyExit();

        vm.prank(owner);
        vault.reactivate(1);

        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0);
    }

    // ── version ─────────────────────────────────────

    function test_version() public view {
        assertEq(vault.version(), "3.5.0");
    }
}
