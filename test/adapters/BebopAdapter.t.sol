// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {MockBebop} from "../mocks/MockVenues.sol";
import {BebopAdapter} from "../../src/adapters/BebopAdapter.sol";

/// @notice Verifies the BebopAdapter wraps Bebop (no recipient arg — pays
/// msg.sender, so the adapter forwards) behind `IPropAMM`.
contract BebopAdapterTest is Test {
    TestERC20 internal tokenIn;
    TestERC20 internal tokenOut;
    MockBebop internal bebop;
    BebopAdapter internal adapter;

    address internal recipient = makeAddr("recipient");
    uint256 internal constant AMOUNT_IN = 100 ether;

    function setUp() public {
        tokenIn = new TestERC20("In", "IN");
        tokenOut = new TestERC20("Out", "OUT");
        bebop = new MockBebop();
        bebop.setOutput(200 ether);
        tokenOut.mint(address(bebop), 1_000_000 ether);
        adapter = new BebopAdapter(address(bebop));
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

    function test_swap_forwardsToRecipient() public {
        tokenIn.mint(address(adapter), AMOUNT_IN);

        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient);

        assertEq(tokenOut.balanceOf(recipient), 200 ether);
        assertEq(tokenOut.balanceOf(address(adapter)), 0); // forwarded, nothing stranded
        assertEq(tokenIn.balanceOf(address(adapter)), 0); // pulled by Bebop
        assertEq(tokenIn.allowance(address(adapter), address(bebop)), 0); // approval reset
    }

    function test_swap_revertsWhenVenueUnderfills() public {
        bebop.setOutput(100 ether); // below the requested minimum
        tokenIn.mint(address(adapter), AMOUNT_IN);

        vm.expectRevert();
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient);
    }
}
