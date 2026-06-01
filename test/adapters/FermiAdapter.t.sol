// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {MockFermi} from "../mocks/MockVenues.sol";
import {FermiAdapter} from "../../src/adapters/FermiAdapter.sol";

/// @notice Verifies the FermiAdapter wraps FermiSwap behind `IPropAMM`.
contract FermiAdapterTest is Test {
    TestERC20 internal tokenIn;
    TestERC20 internal tokenOut;
    MockFermi internal fermi;
    FermiAdapter internal adapter;

    address internal recipient = makeAddr("recipient");
    uint256 internal constant AMOUNT_IN = 100 ether;

    function setUp() public {
        tokenIn = new TestERC20("In", "IN");
        tokenOut = new TestERC20("Out", "OUT");
        fermi = new MockFermi();
        fermi.setOutput(200 ether);
        tokenOut.mint(address(fermi), 1_000_000 ether);
        adapter = new FermiAdapter(address(fermi));
    }

    function test_isActive_true() public view {
        assertTrue(adapter.isActive(address(tokenIn), address(tokenOut)));
    }

    function test_getPairs_empty() public view {
        assertEq(adapter.getPairs().length, 0);
    }

    function test_quote_returnsVenueQuote() public {
        assertEq(adapter.quote(address(tokenIn), address(tokenOut), AMOUNT_IN), 200 ether);
    }

    function test_swap_deliversToRecipient() public {
        // The router pushes the input to the venue before calling swap.
        tokenIn.mint(address(adapter), AMOUNT_IN);

        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient);

        assertEq(tokenOut.balanceOf(recipient), 200 ether);
        assertEq(tokenIn.balanceOf(address(adapter)), 0); // input forwarded to Fermi
        assertEq(tokenIn.allowance(address(adapter), address(fermi)), 0); // approval reset
    }

    function test_swap_revertsWhenVenueUnderfills() public {
        fermi.setOutput(100 ether); // below the requested minimum
        tokenIn.mint(address(adapter), AMOUNT_IN);

        vm.expectRevert();
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient);
    }
}
