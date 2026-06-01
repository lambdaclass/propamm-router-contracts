// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BaseTest} from "./Base.t.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Exercises the owner-managed propAMM whitelist: add, remove, views,
/// access control, and input validation.
contract PropAMMRouterWhitelistTest is BaseTest {
    address internal venueA = makeAddr("venueA");
    address internal venueB = makeAddr("venueB");

    event PropAMMAdded(address indexed venue);
    event PropAMMRemoved(address indexed venue);

    function test_freshRouterHasNoPropAMMs() public view {
        assertEq(router.propAMMCount(), 0);
        assertEq(router.propAMMs().length, 0);
        assertFalse(router.isPropAMM(venueA));
    }

    function test_ownerCanAddPropAMM() public {
        vm.prank(owner);
        router.addPropAMM(venueA);

        assertTrue(router.isPropAMM(venueA));
        assertEq(router.propAMMCount(), 1);
        assertEq(router.propAMMs()[0], venueA);
    }

    function test_addPropAMM_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit PropAMMAdded(venueA);
        vm.prank(owner);
        router.addPropAMM(venueA);
    }

    function test_addPropAMM_revertsForNonOwner() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.addPropAMM(venueA);
    }

    function test_addPropAMM_revertsOnZeroAddress() public {
        vm.expectRevert(PropAMMRouter.ZeroAddress.selector);
        vm.prank(owner);
        router.addPropAMM(address(0));
    }

    function test_addPropAMM_revertsWhenEqualsFallback() public {
        vm.expectRevert(PropAMMRouter.FallbackCannotBeWhitelisted.selector);
        vm.prank(owner);
        router.addPropAMM(fallbackSwapRouter);
    }

    function test_addPropAMM_revertsOnDuplicate() public {
        vm.prank(owner);
        router.addPropAMM(venueA);

        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.PropAMMAlreadyWhitelisted.selector, venueA));
        vm.prank(owner);
        router.addPropAMM(venueA);
    }

    function test_ownerCanRemovePropAMM() public {
        vm.startPrank(owner);
        router.addPropAMM(venueA);
        router.addPropAMM(venueB);
        router.removePropAMM(venueA);
        vm.stopPrank();

        assertFalse(router.isPropAMM(venueA));
        assertTrue(router.isPropAMM(venueB));
        assertEq(router.propAMMCount(), 1);
        assertEq(router.propAMMs()[0], venueB);
    }

    function test_removePropAMM_emitsEvent() public {
        vm.prank(owner);
        router.addPropAMM(venueA);

        vm.expectEmit(true, false, false, false);
        emit PropAMMRemoved(venueA);
        vm.prank(owner);
        router.removePropAMM(venueA);
    }

    function test_removePropAMM_revertsForNonOwner() public {
        vm.prank(owner);
        router.addPropAMM(venueA);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.removePropAMM(venueA);
    }

    function test_removePropAMM_revertsWhenNotWhitelisted() public {
        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.NotWhitelisted.selector, venueA));
        vm.prank(owner);
        router.removePropAMM(venueA);
    }
}
