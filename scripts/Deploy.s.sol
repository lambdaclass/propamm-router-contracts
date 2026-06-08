// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {BlitzRouter} from "../src/BlitzRouter.sol";
import {RouterAccessManager} from "../src/RouterAccessManager.sol";

/// @notice Deploys the `RouterAccessManager` authority and the UUPS router proxy
/// under it, then activates the policy with a single `configureRouter` call.
///
/// The access policy — role catalog, selector->role wiring, and the execution
/// delays — is codified in `RouterAccessManager` itself, not here. This script
/// only supplies the deployment-specific role holders and runs the (optional)
/// governance handoff.
///
/// Required env:
///   ROUTER_ADMIN     bootstrap admin; MUST be the account you broadcast from.
///   ROUTER_UPGRADER  holder of UPGRADER_ROLE (upgrades + fallback config + rescue).
///   ROUTER_GUARDIAN  holder of GUARDIAN_ROLE (instant pause).
/// Optional env (with defaults):
///   ROUTER_RESUMER     holder of RESUMER_ROLE (unpause). Default: ROUTER_UPGRADER.
///   ROUTER_LISTER      holder of LISTING_ROLE (venue whitelist). Default: ROUTER_UPGRADER.
///   GOV_ADMIN          governance multisig to receive ADMIN_ROLE. Default: unset (skip handoff).
///   ADMIN_EXEC_DELAY   execution delay granted to GOV_ADMIN, seconds. Default: 7 days.
///   RENOUNCE_BOOTSTRAP if true, ROUTER_ADMIN renounces ADMIN_ROLE after granting GOV_ADMIN. Default: false.
contract Deploy is Script {
    // Fallback venue (Uniswap V3 SwapRouter + Quoter) wired at initialization.
    address swapRouter = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address quoter = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    function run() public {
        vm.startBroadcast();

        // 1. Authority. Role grants + delays are codified in the manager; this
        // only passes the deployment-specific holders. ROUTER_ADMIN is the
        // bootstrap admin (delay 0) and must be the broadcasting account.
        address upgrader = vm.envAddress("ROUTER_UPGRADER");
        RouterAccessManager manager = new RouterAccessManager(
            vm.envAddress("ROUTER_ADMIN"),
            upgrader,
            vm.envAddress("ROUTER_GUARDIAN"),
            vm.envOr("ROUTER_RESUMER", upgrader),
            vm.envOr("ROUTER_LISTER", upgrader)
        );

        // 2. Router proxy, governed by the manager from initialization.
        address proxy = Upgrades.deployUUPSProxy(
            "BlitzRouter.sol", abi.encodeCall(BlitzRouter.initialize, (swapRouter, quoter, address(manager)))
        );

        // 3. Activate the on-chain policy: wires selectors->roles and locks in
        // the re-gating delay, atomically. One-shot, defined in the manager.
        manager.configureRouter(proxy);

        // 4. Optional secure handoff of ADMIN_ROLE to governance.
        _handoff(manager);

        vm.stopBroadcast();

        console.log("access manager:", address(manager));
        console.log("router proxy:  ", proxy);
    }

    /// @dev Give ADMIN_ROLE to governance (with its own execution delay) and
    /// optionally drop the bootstrap key. Leaving the bootstrap admin in place
    /// keeps a delay-0 master key alive — only skip the renounce knowingly.
    function _handoff(RouterAccessManager manager) internal {
        address admin = vm.envAddress("ROUTER_ADMIN");
        address govAdmin = vm.envOr("GOV_ADMIN", address(0));
        if (govAdmin == address(0) || govAdmin == admin) {
            console.log("WARNING: no GOV_ADMIN handoff. ROUTER_ADMIN remains a delay-0 master key.");
            return;
        }
        manager.grantRole(manager.ADMIN_ROLE(), govAdmin, uint32(vm.envOr("ADMIN_EXEC_DELAY", uint256(7 days))));
        if (vm.envOr("RENOUNCE_BOOTSTRAP", false)) {
            manager.renounceRole(manager.ADMIN_ROLE(), admin);
            console.log("gov admin set; bootstrap admin renounced. gov:", govAdmin);
        } else {
            console.log("gov admin granted; bootstrap admin still active (renounce once verified). gov:", govAdmin);
        }
    }
}
