// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPropAMMExactOut} from "./mocks/MockPropAMMExactOut.sol";

/// @notice Exercises a venue implementing {IPropAMMExactOut} to prove the
/// exact-output contract is implementable as specified: exact delivery, an
/// `amountInMax` ceiling, refund of the unspent input to `msg.sender`, and an
/// exact-output quote consistent with execution. This test contract plays the
/// role of the funding caller (the future router), so `msg.sender` inside the
/// venue is `address(this)` and the refund lands back here.
contract IPropAMMExactOutTest is Test {
    MockPropAMMExactOut internal venue;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal recipient = address(0xCAFE);
    uint256 internal constant LIQUIDITY = 1_000_000e18;

    function setUp() public {
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");
        // 1 tokenOut costs 2 tokenIn.
        venue = new MockPropAMMExactOut(2, 1);
        // Fund the venue with tokenOut liquidity and this caller with tokenIn.
        tokenOut.mint(address(venue), LIQUIDITY);
        tokenIn.mint(address(this), LIQUIDITY);
    }

    function _deadline() private view returns (uint256) {
        return block.timestamp + 1;
    }

    // --- swapExactOut ------------------------------------------------------

    function test_swapExactOut_deliversExactOutAndRefundsRemainder() public {
        uint256 amountOut = 100e18;
        uint256 required = 200e18; // 100 * 2/1
        uint256 amountInMax = 250e18; // 50 buffer over the required input

        // Push-payment: caller transfers the ceiling to the venue first.
        tokenIn.transfer(address(venue), amountInMax);
        uint256 callerBalAfterPush = tokenIn.balanceOf(address(this));

        uint256 amountIn = venue.swapExactOut(
            address(tokenIn), address(tokenOut), amountOut, amountInMax, recipient, _deadline()
        );

        // Exactly amountOut delivered to recipient.
        assertEq(tokenOut.balanceOf(recipient), amountOut);
        // Reported and actual input consumed equals the required amount.
        assertEq(amountIn, required);
        assertEq(tokenIn.balanceOf(address(venue)), required);
        // Unspent input refunded to msg.sender (this caller).
        assertEq(tokenIn.balanceOf(address(this)), callerBalAfterPush + (amountInMax - required));
    }

    function test_swapExactOut_noRefundWhenExactlyFunded() public {
        uint256 amountOut = 100e18;
        uint256 required = 200e18;

        tokenIn.transfer(address(venue), required);
        uint256 callerBalAfterPush = tokenIn.balanceOf(address(this));

        uint256 amountIn = venue.swapExactOut(
            address(tokenIn), address(tokenOut), amountOut, required, recipient, _deadline()
        );

        assertEq(amountIn, required);
        assertEq(tokenOut.balanceOf(recipient), amountOut);
        // Nothing left to refund.
        assertEq(tokenIn.balanceOf(address(this)), callerBalAfterPush);
    }

    function test_swapExactOut_revertsWhenRequiredExceedsMax() public {
        uint256 amountOut = 100e18; // requires 200e18
        uint256 amountInMax = 150e18; // below the required input

        tokenIn.transfer(address(venue), amountInMax);

        vm.expectRevert(bytes("exceeds amountInMax"));
        venue.swapExactOut(address(tokenIn), address(tokenOut), amountOut, amountInMax, recipient, _deadline());
    }

    function test_swapExactOut_revertsWhenInactive() public {
        venue.setActive(false);
        tokenIn.transfer(address(venue), 250e18);

        vm.expectRevert(bytes("inactive"));
        venue.swapExactOut(address(tokenIn), address(tokenOut), 100e18, 250e18, recipient, _deadline());
    }

    // --- quoteExactOut -----------------------------------------------------

    function test_quoteExactOut_returnsRequiredInput() public view {
        uint256 amountOut = 100e18;
        uint256 amountIn = venue.quoteExactOut(address(tokenIn), address(tokenOut), amountOut);
        assertEq(amountIn, 200e18);
    }

    function test_quoteExactOut_roundsUp() public {
        // 1 tokenOut costs 1/3 tokenIn: 10 wei out needs ceil(10/3) = 4 wei in,
        // never 3 — rounding must favor the venue, not under-charge.
        MockPropAMMExactOut cheapVenue = new MockPropAMMExactOut(1, 3);
        assertEq(cheapVenue.quoteExactOut(address(tokenIn), address(tokenOut), 10), 4);
    }

    function test_quoteExactOut_revertsWhenInactive() public {
        venue.setActive(false);
        vm.expectRevert(bytes("inactive"));
        venue.quoteExactOut(address(tokenIn), address(tokenOut), 100e18);
    }

    // --- inherited exact-input surface (smoke test) ------------------------

    function test_swap_exactIn_deliversProportionalOutput() public {
        uint256 amountIn = 200e18;
        tokenIn.transfer(address(venue), amountIn);
        uint256 amountOut = venue.swap(
            address(tokenIn), address(tokenOut), amountIn, 0, recipient, _deadline()
        );
        assertEq(amountOut, 100e18);
        assertEq(tokenOut.balanceOf(recipient), 100e18);
    }
}
