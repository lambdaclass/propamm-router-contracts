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
        // (fresh deploy). Before upgrading an existing proxy, confirm the live
        // `fallbackFee` is non-zero — a 0 value (e.g. an enum-era proxy that never
        // had `fallbackFee`) makes the fallback resolve to tier 0 (invalid) and
        // revert for all unconfigured pairs. If so, ship a reinitializer that
        // backfills `fallbackFee = 3000` and pass its calldata below instead of "".
        Upgrades.upgradeProxy(
            proxy,
            newImplName,
            "" // no reinitializer
        );

        vm.stopBroadcast();

        console.log("proxy upgraded: ", proxy);
    }
}
