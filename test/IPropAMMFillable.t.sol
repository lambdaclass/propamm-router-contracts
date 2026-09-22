// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IPropAMMFillable} from "../src/interfaces/IPropAMMFillable.sol";
import {MockFillablePropAMM} from "./mocks/MockFillablePropAMM.sol";
import {MockPropAMM} from "./mocks/MockPropAMM.sol";

contract IPropAMMFillableTest is Test {
    function test_interfaceId_isDetectedByERC165Checker() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        assertTrue(ERC165Checker.supportsInterface(address(venue), type(IPropAMMFillable).interfaceId));
    }

    function test_interfaceId_notAdvertisedWhenDisabled() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        venue.setSupportsFillable(false);
        assertFalse(ERC165Checker.supportsInterface(address(venue), type(IPropAMMFillable).interfaceId));
    }

    /// @dev A plain propAMM has no ERC-165 at all. ERC165Checker must report
    /// false rather than revert, since the router probes every venue this way.
    function test_plainPropAMM_isNotDetected() public {
        MockPropAMM venue = new MockPropAMM();
        assertFalse(ERC165Checker.supportsInterface(address(venue), type(IPropAMMFillable).interfaceId));
    }

    function test_quoteFillable_returnsConfiguredPair() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        venue.setFillable(500e6);
        venue.setOut(1e18);
        (uint256 fill, uint256 out) = venue.quoteFillable(address(1), address(2), 1000e6);
        assertEq(fill, 500e6);
        assertEq(out, 1e18);
    }
}
