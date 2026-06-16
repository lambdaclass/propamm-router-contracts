// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal FermiSwap stand-in for the bespoke `IFermiSwapper` dispatch
/// path (`venue == FERMI_ROUTER` in `_dispatchVenue` / `_dispatchQuoteVenue`).
/// @dev Stateless on purpose: tests place this code at the hard-coded
/// `FERMI_ROUTER` address with `vm.etch`, which copies code but NOT storage, so
/// both the quote and the delivered amount are derived from the mock's own
/// `tokenOut` balance (funded by the test via `mint`) instead of a stored config
/// field. Mirrors the allowance-pull model the real router relies on:
/// `fermiSwapWithAllowances` pulls `tokenIn` from the caller (the router) using
/// the allowance the router granted, then delivers `tokenOut` to `recipient`.
contract MockFermi {
    function fermiSwapWithAllowances(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256, /* amountCheck — the router re-checks the delivered delta itself */
        address recipient
    ) external returns (uint256 amountIn, uint256 amountOut) {
        amountIn = uint256(amountSpecified);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenOut).transfer(recipient, amountOut);
    }

    function quoteAmounts(address, /* tokenIn */ address tokenOut, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        return (uint256(amountSpecified), IERC20(tokenOut).balanceOf(address(this)));
    }
}
