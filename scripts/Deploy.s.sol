// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {FermiAdapter} from "../src/adapters/FermiAdapter.sol";
import {KipseliAdapter} from "../src/adapters/KipseliAdapter.sol";
import {BebopAdapter} from "../src/adapters/BebopAdapter.sol";
import {FERMI_ROUTER} from "../src/interfaces/IFermiSwapper.sol";
import {BEBOP_ROUTER} from "../src/interfaces/IBebopRouter.sol";
import {KIPSELI_PAMM} from "../src/interfaces/IKipseliPAMM.sol";
import {KIPSELI_QUOTER} from "../src/interfaces/IKipseliQuoter.sol";

/// @notice Fresh deploy: deploys the router proxy and the three venue adapters,
/// then seeds the whitelist.
/// @dev Seeding calls `initializeV2` (`onlyOwner`), so the broadcaster must be
/// the configured `ROUTER_OWNER`.
contract Deploy is Script {
    address swapRouter = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address quoter = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    function run() public {
        address owner = vm.envAddress("ROUTER_OWNER");

        vm.startBroadcast();

        address proxy = Upgrades.deployUUPSProxy(
            "PropAMMRouter.sol", abi.encodeCall(PropAMMRouter.initialize, (swapRouter, quoter, owner))
        );

        address fermiAdapter = address(new FermiAdapter(FERMI_ROUTER));
        address kipseliAdapter = address(new KipseliAdapter(KIPSELI_PAMM, KIPSELI_QUOTER));
        address bebopAdapter = address(new BebopAdapter(BEBOP_ROUTER));

        address[] memory initialPropAMMs = new address[](3);
        initialPropAMMs[0] = fermiAdapter;
        initialPropAMMs[1] = kipseliAdapter;
        initialPropAMMs[2] = bebopAdapter;

        PropAMMRouter(proxy).initializeV2(initialPropAMMs);

        vm.stopBroadcast();

        console.log("proxy:", proxy);
        console.log("owner:", owner);
        console.log("fermiAdapter:", fermiAdapter);
        console.log("kipseliAdapter:", kipseliAdapter);
        console.log("bebopAdapter:", bebopAdapter);
    }
}
