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

    /// @dev First arg (`tokenIn`) is unused; the quote is derived from the mock's
    /// own `tokenOut` balance.
    function quoteAmounts(address, address tokenOut, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        return (uint256(amountSpecified), IERC20(tokenOut).balanceOf(address(this)));
    }
}

/// @notice FermiSwap stand-in whose entrypoints always revert — a "venue is down
/// / wrong interface" stub. Etched at `FERMI_ROUTER` in place of `MockFermi` to
/// drive the `_coreSwap` try/catch into the Uniswap fallback for the bespoke
/// `venue == FERMI_ROUTER` dispatch (the catch arm the live fork test can't reach,
/// since its deployed bytecode dispatches the migrated Fermi venue generically).
contract MockFermiReverting {
    error FermiDown();

    function fermiSwapWithAllowances(address, address, int256, uint256, address)
        external
        pure
        returns (uint256, uint256)
    {
        revert FermiDown();
    }

    function quoteAmounts(address, address, int256) external pure returns (uint256, uint256) {
        revert FermiDown();
    }
}
