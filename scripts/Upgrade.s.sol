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

/// @notice Upgrades the router to the modifiable-whitelist implementation and
/// atomically seeds the whitelist with the Fermi/Kipseli/Bebop adapters.
/// @dev `initializeV2` is `onlyOwner`, so the broadcaster must be the proxy
/// owner. The whitelist storage is namespaced (ERC-7201), so this upgrade does
/// not move any sequential storage slot. If `Upgrades.upgradeProxy`'s safety
/// check needs the deployed implementation as a layout reference, set it via
/// `Options.referenceContract` or a `@custom:oz-upgrades-from` annotation.
contract Upgrade is Script {
    function run() public {
        address proxy = vm.envAddress("ROUTER_PROXY");

        vm.startBroadcast();

        // Deploy the adapters that bring the existing venues onto `IPropAMM`.
        address fermiAdapter = address(new FermiAdapter(FERMI_ROUTER));
        address kipseliAdapter = address(new KipseliAdapter(KIPSELI_PAMM, KIPSELI_QUOTER));
        address bebopAdapter = address(new BebopAdapter(BEBOP_ROUTER));

        address[] memory initialPropAMMs = new address[](3);
        initialPropAMMs[0] = fermiAdapter;
        initialPropAMMs[1] = kipseliAdapter;
        initialPropAMMs[2] = bebopAdapter;

        Upgrades.upgradeProxy(proxy, "PropAMMRouter.sol", abi.encodeCall(PropAMMRouter.initializeV2, (initialPropAMMs)));

        vm.stopBroadcast();

        console.log("proxy upgraded:", proxy);
        console.log("fermiAdapter:", fermiAdapter);
        console.log("kipseliAdapter:", kipseliAdapter);
        console.log("bebopAdapter:", bebopAdapter);
    }
}
