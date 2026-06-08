// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {RouterAccessManager} from "../src/RouterAccessManager.sol";

/// @notice SCHEDULES a UUPS upgrade through the AccessManager. Upgrades are now
/// gated behind UPGRADER_ROLE's execution delay, so they can no longer be done
/// in a single transaction — this script deploys + validates the new
/// implementation and queues the `upgradeToAndCall`. After the delay elapses,
/// run `Execute.s.sol` (or call `upgradeToAndCall` directly from the same
/// upgrader account) to apply it.
///
/// MUST be broadcast from the UPGRADER_ROLE holder: the scheduled op is keyed by
/// (caller, target, data), so the same account must execute it.
///
/// Required env:
///   ACCESS_MANAGER   the RouterAccessManager address.
///   ROUTER_PROXY     the router proxy to upgrade.
///   ROUTER_IMPL_NAME new implementation contract (e.g. "BlitzRouterV2.sol").
/// Optional env:
///   ROUTER_IMPL_REFERENCE  reference contract for storage-layout validation
///                          (e.g. "BlitzRouter.sol"). Recommended unless the
///                          new impl declares its predecessor via an
///                          oz-upgrades-from annotation.
contract Upgrade is Script {
    function run() public {
        address managerAddr = vm.envAddress("ACCESS_MANAGER");
        address proxy = vm.envAddress("ROUTER_PROXY");
        string memory newImplName = vm.envString("ROUTER_IMPL_NAME");

        Options memory opts;
        // Validate the new layout against the currently deployed one when a
        // reference is supplied; otherwise rely on the new impl's annotation.
        opts.referenceContract = vm.envOr("ROUTER_IMPL_REFERENCE", string(""));

        vm.startBroadcast();

        // Deploy + upgrade-safety-validate the new implementation WITHOUT applying it.
        address newImpl = Upgrades.prepareUpgrade(newImplName, opts);

        // The exact call the timelock will perform. No reinitializer payload here.
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));

        // when = 0 => earliest allowed: now + the upgrader's execution delay.
        (bytes32 operationId,) = RouterAccessManager(managerAddr).schedule(proxy, data, 0);

        vm.stopBroadcast();

        console.log("new implementation: ", newImpl);
        console.log("proxy:              ", proxy);
        console.log("operationId:");
        console.logBytes32(operationId);
        console.log("ready at (unix):    ", RouterAccessManager(managerAddr).getSchedule(operationId));
        console.log("EXEC_TARGET = proxy above; EXEC_DATA =");
        console.logBytes(data);
        console.log("After the delay, run Execute.s.sol with those values (same broadcaster).");
    }
}
