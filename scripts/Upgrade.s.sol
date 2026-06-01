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
        //
        // Venue-whitelist precondition: the whitelist (`_whitelistedVenues`) is
        // seeded only in `initialize` (fresh deploy). A proxy deployed before the
        // whitelist existed comes up with NO whitelisted propAMMs, so every swap
        // silently routes through the Uniswap fallback until they are added. To
        // backfill atomically with the upgrade, pass
        // `abi.encodeCall(PropAMMRouter.initializeVenueWhitelist, ())` as the call
        // below instead of "" (it is `reinitializer(2)`, so it runs at most once).
        Upgrades.upgradeProxy(
            proxy,
            newImplName,
            "" // no reinitializer
        );

        vm.stopBroadcast();

        console.log("proxy upgraded: ", proxy);
    }
}
