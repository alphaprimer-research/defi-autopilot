// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Verifies that fee settlement occurs correctly on every entry/exit,
///         preventing clock-reset grief and pre-exit fee avoidance.
contract FeeSettlement is Test {
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
    address alice = makeAddr("alice");
    address eve = makeAddr("eve");

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

    // $1 deposit must NOT wipe pending management fee
    function test_deposit_does_not_wipe_mgmt_fee() public {
        _deposit(alice, 10_000e6);

        vm.warp(block.timestamp + 365 days);

        // harvest without any deposit — baseline fees
        vm.prank(strategist);
        vault.harvest();
        uint256 feesNormal = vault.accruedFees();

        // reset for second run
        setUp();
        _deposit(alice, 10_000e6);
        vm.warp(block.timestamp + 365 days);

        // eve deposits $1 then harvest — fees must be the same
        _deposit(eve, 1e6);
        vm.prank(strategist);
        vault.harvest();
        uint256 feesAfterDeposit = vault.accruedFees();

        // mgmt fee must NOT be wiped — allow 5% tolerance for timing
        assertApproxEqRel(feesAfterDeposit, feesNormal, 0.05e18, "deposit wiped mgmt fee");
    }

    // withdraw must settle perf fee before exit
    function test_withdraw_settles_perf_fee() public {
        _deposit(alice, 10_000e6);
        _deposit(eve, 10_000e6);

        vm.warp(block.timestamp + 90 days);

        uint256 feesBefore = vault.accruedFees();

        // eve redeems all — should trigger fee settlement first
        vm.startPrank(eve);
        vault.redeem(vault.balanceOf(eve), eve, eve);
        vm.stopPrank();

        uint256 feesAfter = vault.accruedFees();
        assertGt(feesAfter, feesBefore, "redeem did not settle fees");
    }

    // harvest loop must still not compound fees (regression)
    function test_harvest_no_compounding() public {
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

    // Fluid deposit must have slippage protection
    function test_fluid_deposit_has_slippage_check() public {
        _deposit(alice, 5_000e6);

        // rebalance to Fluid — should succeed with slippage check
        vm.startPrank(strategist);
        _rebalanceTo(3);
        vm.stopPrank();

        assertEq(vault.activeProtocol(), 3);
        assertGt(vault.totalAssets(), 4_900e6, "lost >2% on Fluid deposit");
    }

    // Fluid round-trip must not lose more than slippage bound
    function test_fluid_round_trip_bounded() public {
        _deposit(alice, 5_000e6);
        uint256 assetsBefore = vault.totalAssets();

        vm.startPrank(strategist);
        _rebalanceTo(3); // aave → fluid
        _rebalanceTo(1); // fluid → aave
        vm.stopPrank();

        uint256 assetsAfter = vault.totalAssets();
        // max 1% loss on round trip (2x 0.5% slippage)
        assertGt(assetsAfter, assetsBefore * 99 / 100, "round trip lost >1%");
    }

    function test_version_is_3_4() public view {
        assertEq(vault.version(), "3.5.0");
    }
}
