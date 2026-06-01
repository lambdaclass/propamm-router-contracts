// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BaseTest} from "./Base.t.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @notice Exercises `initializeV2`, the one-time `reinitializer(2)` that seeds
/// the whitelist during the upgrade that introduces it.
contract MigrationTest is BaseTest {
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");
    address internal c = makeAddr("c");

    function _venues() internal view returns (address[] memory venues) {
        venues = new address[](3);
        venues[0] = a;
        venues[1] = b;
        venues[2] = c;
    }

    function test_initializeV2_seedsWhitelist() public {
        vm.prank(owner);
        router.initializeV2(_venues());

        assertEq(router.propAMMCount(), 3);
        assertTrue(router.isPropAMM(a));
        assertTrue(router.isPropAMM(b));
        assertTrue(router.isPropAMM(c));
    }

    function test_initializeV2_cannotRunTwice() public {
        vm.prank(owner);
        router.initializeV2(_venues());

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(owner);
        router.initializeV2(_venues());
    }

    function test_initializeV2_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.initializeV2(_venues());
    }

    function test_initializeV2_revertsOnZeroAddress() public {
        address[] memory venues = new address[](1);
        venues[0] = address(0);

        vm.expectRevert(PropAMMRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.initializeV2(venues);
    }
}
