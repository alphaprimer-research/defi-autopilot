// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeployTimelock is Script {
    function run() external {
        address safe = vm.envAddress("SAFE");
        uint256 delay = vm.envUint("DELAY");

        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        address[] memory executors = new address[](1);
        executors[0] = safe;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        new TimelockController(delay, proposers, executors, address(0));
        vm.stopBroadcast();
    }
}
