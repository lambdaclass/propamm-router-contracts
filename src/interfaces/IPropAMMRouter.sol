// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMRouter
/// @notice Interface for a router that executes single-hop swaps against a
/// proprietary AMM (FermiSwap, Kipseli, or Bebop) or a public-venue fallback
/// (Uniswap V3), with the public venue also serving as the recovery path when
/// the chosen proprietary AMM cannot fill the swap.
/// @dev Venues are identified by address rather than an enum. The set of
/// proprietary venues a caller may name explicitly is the implementation's
/// whitelist (FermiSwap, Kipseli, Bebop). Uniswap V3 is never named directly:
/// it is folded into `quoteV1` as a baseline price and is only ever reached
/// automatically (best-quote selection in `swapV1`, or as the failure fallback).
/// The Uniswap fallback fee tier is selected internally by the implementation,
/// so callers never pass one.
interface IPropAMMRouter {
    /// @notice Swaps an exact amount of `tokenIn` for as much `tokenOut` as
    /// possible, routing through whichever venue quotes best and falling back
    /// to Uniswap V3 if the chosen proprietary venue fails to fill.
    /// @dev The caller must have approved this contract to spend at least
    /// `amountIn` of `tokenIn`. Reverts if the final output is below
    /// `amountOutMin`. The executing venue is chosen internally by comparing
    /// quotes across the proprietary venues and Uniswap V3.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`; the
    /// swap reverts if the actual output is lower.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` actually received by `recipient`.
    /// @return executedVenue The address of the venue that filled the swap; the
    /// Uniswap V3 SwapRouter address when the fallback ran.
    function swapV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut, address executedVenue);

    /// @notice Swaps an exact amount of `tokenIn` through a caller-specified
    /// proprietary venue, falling back to Uniswap V3 if that venue fails.
    /// @dev `venue` must be one of the whitelisted proprietary AMMs; Uniswap V3
    /// cannot be named here and is only reached as the fallback. The caller
    /// must have approved this contract to spend at least `amountIn` of
    /// `tokenIn`. Reverts `UnknownVenue` if `venue` is not whitelisted, or
    /// reverts if the final output is below `amountOutMin`.
    /// @param venue The proprietary venue to attempt the swap on first.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` actually received by `recipient`.
    function swapViaVenueV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /// @notice Quotes `amount` of `tokenIn` against every venue (the
    /// proprietary AMMs and the Uniswap V3 baseline) and returns the best
    /// output along with the venue that produced it.
    /// @dev Venues that revert when quoting are skipped. Reverts
    /// `NoQuotesAvailable` if no venue can produce a quote. Not `view`: the
    /// Uniswap V3 QuoterV2 branch prices via revert-based simulation. Call this
    /// via `eth_call` (staticcall) from off-chain.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return bestQuote The best `tokenOut` amount across all venues.
    /// @return venue The venue that produced `bestQuote`; the Uniswap V3
    /// SwapRouter address if the Uniswap baseline won.
    function quoteV1(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 bestQuote, address venue);

    /// @notice Quotes `amount` of `tokenIn` against a single whitelisted
    /// proprietary venue.
    /// @dev Not `view`: a venue's quote source may price via revert-based
    /// simulation. Call this via `eth_call` (staticcall) from off-chain.
    /// Reverts `UnknownVenue` if `venue` is not a whitelisted proprietary AMM.
    /// Bubbles up any revert from the underlying venue (e.g. unsupported pair,
    /// no liquidity, stale Kipseli oracle).
    /// @param venue The proprietary venue to quote against.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function quoteVenueV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 amountOut);
}
