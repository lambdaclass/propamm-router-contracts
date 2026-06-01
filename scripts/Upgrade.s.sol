// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract Upgrade is Script {
    function run() public {
        address proxy = vm.envAddress("ROUTER_PROXY");
        string memory newImplName = vm.envString("ROUTER_IMPL_NAME");

        vm.startBroadcast();

        // Per-pair fee precondition: unconfigured pairs resolve their Uniswap
        // fallback tier to `fallbackFee`, which is set (=3000) only in `initialize`
        // (fresh deploy) and never re-applied on upgrade. A proxy that predates the
        // per-pair fee map (an enum-era deployment) therefore carries `fallbackFee = 0`
        // after this bare upgrade, making the fallback resolve to tier 0 (invalid) and
        // revert for every unconfigured pair. The fee config is restored as a SEPARATE
        // owner step right after this upgrade: run `scripts/setupRouterVariables.s.sol`
        // (sets `fallbackFee = 3000` + the deep per-pair tiers). Consider `pause()`-ing
        // the router across the two steps if swaps could arrive in between.
        Upgrades.upgradeProxy(
            proxy,
            newImplName,
            "" // no reinitializer; fee config restored post-upgrade by setupRouterVariables.s.sol
        );

        vm.stopBroadcast();

        console.log("proxy upgraded: ", proxy);
    }
}
