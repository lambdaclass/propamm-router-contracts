// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {RouterAccessManager} from "../src/RouterAccessManager.sol";

/// @notice Executes a previously SCHEDULED, now-ready operation through the
/// AccessManager. Generic: works for any delayed admin call (upgrade, fallback
/// reconfig, unpause, rescue). The schedule is keyed by (caller, target, data),
/// so this MUST be broadcast from the same account that scheduled it, with the
/// identical calldata.
///
/// Required env:
///   ACCESS_MANAGER  the RouterAccessManager address.
///   EXEC_TARGET     the target contract of the scheduled call (e.g. the proxy).
///   EXEC_DATA       the exact calldata that was scheduled (0x-prefixed hex).
contract Execute is Script {
    function run() public {
        address managerAddr = vm.envAddress("ACCESS_MANAGER");
        address target = vm.envAddress("EXEC_TARGET");
        bytes memory data = vm.envBytes("EXEC_DATA");

        vm.startBroadcast();
        uint32 nonce = RouterAccessManager(managerAddr).execute(target, data);
        vm.stopBroadcast();

        console.log("executed target:", target);
        console.log("nonce:          ", nonce);
    }
}
