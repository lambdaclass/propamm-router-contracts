// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract Upgrade is Script {
    function run() public {
        address proxy = vm.envAddress("ROUTER_PROXY");
        string memory newImplName = vm.envString("ROUTER_IMPL_NAME");

        vm.startBroadcast();

        Upgrades.upgradeProxy(
            proxy,
            newImplName,
            "" // no reinitializer
        );

        vm.stopBroadcast();

        console.log("proxy upgraded: ", proxy);
    }
}
