// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphaPrimerVault} from "../src/AlphaPrimerVault.sol";

contract DeployVault is Script {
    // Arbitrum mainnet
    address constant USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant POOL   = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address constant AUSDC  = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address owner    = vm.envAddress("OWNER"); // timelock or multisig

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AlphaPrimerVault impl = new AlphaPrimerVault();

        bytes memory initData = abi.encodeCall(
            AlphaPrimerVault.initialize,
            (USDC, POOL, AUSDC, owner, 1000, 100) // 10% perf, 1% mgmt
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        vm.stopBroadcast();
    }
}
