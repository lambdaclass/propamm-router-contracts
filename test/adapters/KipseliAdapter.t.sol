// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {MockKipseliPamm, MockKipseliQuoter} from "../mocks/MockVenues.sol";
import {KipseliAdapter} from "../../src/adapters/KipseliAdapter.sol";

/// @notice Verifies the KipseliAdapter wraps the Kipseli propAMM (push-payment,
/// 0-return failure signal) and its separate quoter behind `IPropAMM`.
contract KipseliAdapterTest is Test {
    TestERC20 internal tokenIn;
    TestERC20 internal tokenOut;
    MockKipseliPamm internal pamm;
    MockKipseliQuoter internal quoter;
    KipseliAdapter internal adapter;

    address internal recipient = makeAddr("recipient");
    uint256 internal constant AMOUNT_IN = 100 ether;

    function setUp() public {
        tokenIn = new TestERC20("In", "IN");
        tokenOut = new TestERC20("Out", "OUT");
        pamm = new MockKipseliPamm();
        pamm.setOutput(200 ether);
        tokenOut.mint(address(pamm), 1_000_000 ether);
        quoter = new MockKipseliQuoter();
        quoter.setQuote(180 ether); // deliberately != pamm output, to prove the quoter is used
        adapter = new KipseliAdapter(address(pamm), address(quoter));
    }

    function test_isActive_true() public view {
        assertTrue(adapter.isActive(address(tokenIn), address(tokenOut)));
    }

    function test_getPairs_empty() public view {
        assertEq(adapter.getPairs().length, 0);
    }

    function test_quote_usesQuoter() public {
        assertEq(adapter.quote(address(tokenIn), address(tokenOut), AMOUNT_IN), 180 ether);
    }

    function test_swap_deliversToRecipient() public {
        tokenIn.mint(address(adapter), AMOUNT_IN);

        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient);

        assertEq(tokenOut.balanceOf(recipient), 200 ether);
        assertEq(tokenIn.balanceOf(address(adapter)), 0); // pushed to Kipseli
        assertEq(tokenIn.balanceOf(address(pamm)), AMOUNT_IN);
    }

    function test_swap_revertsOnZeroReturn() public {
        pamm.setReturnZero(true); // Kipseli's failure signal
        tokenIn.mint(address(adapter), AMOUNT_IN);

        vm.expectRevert();
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 0, recipient);
    }

    function test_swap_revertsWhenUnderMin() public {
        pamm.setOutput(100 ether); // below the requested minimum
        tokenIn.mint(address(adapter), AMOUNT_IN);

        vm.expectRevert();
        adapter.swap(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient);
    }
}
