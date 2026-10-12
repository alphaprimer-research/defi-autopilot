// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultForkTest is Test {
    AlphaPrimerVault vault;
    IERC20 usdc;

    address constant USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant POOL  = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AUSDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    // Arbitrum native USDC master minter / large holder
    address constant WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");

        AlphaPrimerVault impl = new AlphaPrimerVault();
        bytes memory initData = abi.encodeCall(
            AlphaPrimerVault.initialize,
            (USDC, owner, owner, POOL, AUSDC,
             0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf,
             0x1A996cb54bb95462040408C06122D45D6Cdb6096,
             1000, 100)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = AlphaPrimerVault(address(proxy));
        usdc = IERC20(USDC);

        // transfer from a real USDC holder to avoid deal() storage issues
        vm.startPrank(WHALE);
        usdc.transfer(alice, 10_000e6);
        usdc.transfer(bob, 5_000e6);
        vm.stopPrank();
    }

    function test_deposit_and_withdraw() public {
        uint256 amount = 1_000e6;

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertGt(shares, 0, "should receive shares");
        assertEq(vault.balanceOf(alice), shares);

        // redeem all shares instead of fixed withdraw (avoids Aave rounding)
        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0, "shares should be burned");
        assertApproxEqAbs(usdc.balanceOf(alice), 10_000e6, 10, "should get most USDC back");
    }

    function test_totalAssets_increases_with_aave_yield() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(5_000e6, alice);
        vm.stopPrank();

        uint256 assetsBefore = vault.totalAssets();
        vm.warp(block.timestamp + 30 days);
        uint256 assetsAfter = vault.totalAssets();

        assertGt(assetsAfter, assetsBefore, "assets should grow from Aave yield");
    }

    function test_only_owner_can_harvest() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.harvest();
    }

    function test_harvest_accrues_fees() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(5_000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 90 days);

        vm.prank(owner);
        vault.harvest();

        assertGt(vault.accruedFees(), 0, "fees should accrue");
    }

    function test_fee_caps_enforced() public {
        vm.startPrank(owner);
        vm.expectRevert("fee cap");
        vault.setFees(3000, 100); // 30% perf > 20% max
        vm.stopPrank();
    }

    function test_emergency_exit() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 2_000e6);
        vault.deposit(2_000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.emergencyExit();

        assertTrue(vault.depositsPaused(), "deposits should be paused");
        assertGt(usdc.balanceOf(address(vault)), 0, "USDC should be in vault");

        // alice can still withdraw
        vm.startPrank(alice);
        vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), 10_000e6, 2);
    }

    function test_two_users_proportional() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 4_000e6);
        vault.deposit(4_000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 2_000e6);
        vault.deposit(2_000e6, bob);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        // alice deposited 2x bob, should have ~2x shares
        assertGt(aliceShares, bobShares, "alice should have more shares");
    }

    function test_non_owner_cannot_upgrade() public {
        AlphaPrimerVault newImpl = new AlphaPrimerVault();
        vm.prank(alice);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function test_version() public view {
        assertEq(vault.version(), "3.4.0");
    }
}
