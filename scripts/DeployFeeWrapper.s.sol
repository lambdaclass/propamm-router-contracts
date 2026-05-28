// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {PropAMMFeeWrapper} from "../src/PropAMMFeeWrapper.sol";

contract DeployFeeWrapper is Script {
    function run() public {
        address router = vm.envAddress("ROUTER_PROXY");        // underlying PropAMMRouter proxy
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint16 feeBps = uint16(vm.envUint("FEE_BPS"));
        address owner = vm.envAddress("ROUTER_OWNER");

        vm.startBroadcast();
        address proxy = Upgrades.deployUUPSProxy(
            "PropAMMFeeWrapper.sol",
            abi.encodeCall(PropAMMFeeWrapper.initialize, (router, feeRecipient, feeBps, owner))
        );
        vm.stopBroadcast();

        console.log("fee wrapper proxy: ", proxy);
        console.log("underlying router: ", router);
    }
}
