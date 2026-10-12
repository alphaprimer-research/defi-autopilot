// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";

contract DeployVault is Script {
    // Arbitrum mainnet — native USDC
    address constant USDC      = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AUSDC     = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address constant COMPOUND  = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address constant FLUID     = 0x1A996cb54bb95462040408C06122D45D6Cdb6096; // fUSDC ERC4626

    function run() external {
        address owner      = vm.envAddress("OWNER");
        address strategist = vm.envAddress("STRATEGIST");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AlphaPrimerVault impl = new AlphaPrimerVault();

        bytes memory initData = abi.encodeCall(
            AlphaPrimerVault.initialize,
            (USDC, owner, strategist, AAVE_POOL, AUSDC,
             COMPOUND, FLUID, 1000, 100)
        );

        new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();
    }
}
