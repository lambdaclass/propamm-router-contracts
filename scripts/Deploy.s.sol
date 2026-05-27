// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";

contract Deploy is Script {
    address swapRouter = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address quoter = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    function run() public {
        address owner = vm.envAddress("ROUTER_OWNER");

        vm.startBroadcast();

        address proxy = Upgrades.deployUUPSProxy(
            "PropAMMRouter.sol",
            abi.encodeCall(
                PropAMMRouter.initialize,
                (swapRouter, quoter, owner)
            )
        );

        vm.stopBroadcast();

        console.log("proxy: ", proxy);
        console.log("owner: ", owner);
    }
}
