// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BaseTest} from "./Base.t.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {MockPropAMM} from "./mocks/MockPropAMM.sol";

/// @notice Exercises quoting and swapping through the `IPropAMM` whitelist plus
/// the Uniswap fallback.
contract PropAMMRouterRoutingTest is BaseTest {
    uint256 internal constant AMOUNT_IN = 100 ether;
    address internal recipient = makeAddr("recipient");
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 100;
    }

    // --- quoteVenueV1 -------------------------------------------------------

    function test_quoteVenueV1_returnsVenueQuote() public {
        MockPropAMM venue = _deployVenue(200 ether);
        assertEq(router.quoteVenueV1(address(venue), address(tokenIn), address(tokenOut), AMOUNT_IN), 200 ether);
    }

    function test_quoteVenueV1_fallbackReturnsUniswapQuote() public {
        mockQuoter.setQuote(150 ether);
        assertEq(router.quoteVenueV1(fallbackSwapRouter, address(tokenIn), address(tokenOut), AMOUNT_IN), 150 ether);
    }

    function test_quoteVenueV1_revertsUnknownVenue() public {
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.quoteVenueV1(makeAddr("notAVenue"), address(tokenIn), address(tokenOut), AMOUNT_IN);
    }

    // --- swapViaVenueV1 -----------------------------------------------------

    function test_swapViaVenueV1_routesThroughVenue() public {
        MockPropAMM venue = _deployVenue(200 ether);
        _fundUser(AMOUNT_IN);

        vm.expectEmit(true, true, true, true);
        emit IPropAMMRouter.Swapped(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient, address(venue)
        );

        vm.prank(user);
        uint256 amountOut = router.swapViaVenueV1(
            address(venue), address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient, deadline
        );

        assertEq(amountOut, 200 ether);
        assertEq(tokenOut.balanceOf(recipient), 200 ether);
        assertEq(tokenIn.balanceOf(user), 0);
        assertEq(tokenIn.balanceOf(address(venue)), AMOUNT_IN); // venue pulled the input
        assertEq(tokenIn.balanceOf(address(router)), 0); // router holds nothing after
    }

    function test_swapViaVenueV1_revertsUnknownVenue() public {
        _fundUser(AMOUNT_IN);
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        vm.prank(user);
        router.swapViaVenueV1(
            makeAddr("notAVenue"), address(tokenIn), address(tokenOut), AMOUNT_IN, 0, recipient, deadline
        );
    }

    // --- quoteV1 / swapV1 best-venue selection ------------------------------

    function test_quoteV1_picksBestVenue() public {
        _deployVenue(200 ether);
        MockPropAMM venueB = _deployVenue(250 ether);
        mockQuoter.setQuote(150 ether);

        (uint256 bestQuote, address venue) = router.quoteV1(address(tokenIn), address(tokenOut), AMOUNT_IN);
        assertEq(bestQuote, 250 ether);
        assertEq(venue, address(venueB));
    }

    function test_swapV1_executesViaBestVenue() public {
        _deployVenue(200 ether);
        MockPropAMM venueB = _deployVenue(250 ether);
        mockQuoter.setQuote(150 ether);
        _fundUser(AMOUNT_IN);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, 250 ether, recipient, deadline);

        assertEq(amountOut, 250 ether);
        assertEq(executedVenue, address(venueB));
        assertEq(tokenOut.balanceOf(recipient), 250 ether);
    }

    function test_swapV1_skipsInactiveVenue() public {
        MockPropAMM venueHigh = _deployVenue(300 ether);
        venueHigh.setActive(false); // best quote, but dead
        MockPropAMM venueLow = _deployVenue(200 ether);
        mockQuoter.setQuote(0); // fallback can't beat venueLow
        _fundUser(AMOUNT_IN);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, 200 ether, recipient, deadline);

        assertEq(executedVenue, address(venueLow));
        assertEq(amountOut, 200 ether);
    }

    function test_swapV1_fallsBackWhenVenueSwapReverts() public {
        MockPropAMM venue = _deployVenue(300 ether); // wins the quote
        venue.setRevertOnSwap(true); // but cannot fill
        mockQuoter.setQuote(150 ether);
        mockSwapRouter.setOutput(150 ether);
        _fundUser(AMOUNT_IN);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, 150 ether, recipient, deadline);

        assertEq(executedVenue, fallbackSwapRouter);
        assertEq(amountOut, 150 ether);
        assertEq(tokenOut.balanceOf(recipient), 150 ether);
    }

    // --- swapViaSelectedVenuesV1 -------------------------------------------

    function test_swapViaSelectedVenuesV1_picksBestAmongSubset() public {
        MockPropAMM venueA = _deployVenue(200 ether);
        MockPropAMM venueB = _deployVenue(250 ether);
        _deployVenue(300 ether); // venueC: highest, but excluded from the subset
        _fundUser(AMOUNT_IN);

        address[] memory selected = new address[](2);
        selected[0] = address(venueA);
        selected[1] = address(venueB);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) = router.swapViaSelectedVenuesV1(
            selected, address(tokenIn), address(tokenOut), AMOUNT_IN, 250 ether, recipient, deadline
        );

        assertEq(executedVenue, address(venueB));
        assertEq(amountOut, 250 ether);
    }
}
