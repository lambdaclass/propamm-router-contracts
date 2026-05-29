// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMRouter
/// @notice Router for single-hop swaps across whitelisted proprietary venues,
/// with a public-venue fallback used when the chosen proprietary venue cannot
/// fill.
/// @dev A venue is either a whitelisted proprietary AMM address or the
/// public-venue fallback, denoted by the implementation's Uniswap V3
/// SwapRouter02 address. The quote/swap functions may return that fallback
/// address to signal the public venue; the per-venue functions accept it too —
/// naming the fallback address routes directly to the public venue. A fallback
/// result returned by `quoteV1` may therefore be passed to either `swapV1` or
/// `swapViaVenueV1`.
interface IPropAMMRouter {
    /// @notice Swaps an exact `amountIn` of `tokenIn` for as much `tokenOut` as
    /// possible, routing through the best-quoting venue and falling back to the
    /// public-venue fallback if the chosen proprietary venue fails to fill.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that receives `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    /// @return executedVenue The proprietary venue that filled the swap, or the
    /// Uniswap V3 SwapRouter02 address when the fallback ran.
    function swapV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut, address executedVenue);

    /// @notice Swaps an exact `amountIn` of `tokenIn` through a caller-specified
    /// venue, falling back to the public venue if a proprietary venue
    /// fails.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts `UnknownVenue` if `venue` is neither a whitelisted
    /// proprietary AMM nor the fallback address, or reverts if the output is
    /// below `amountOutMin`. Naming the fallback address routes directly to the
    /// public venue with no further fallback (it is the fallback).
    /// @param venue The venue to attempt first — a proprietary AMM, or the
    /// fallback address to swap on the public venue directly.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that receives `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    function swapViaVenueV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /// @notice Quotes `amount` of `tokenIn` across every venue and returns the
    /// best output and the venue that produced it.
    /// @dev Venues that revert while quoting are skipped. Reverts
    /// `NoQuotesAvailable` if no venue can quote. Not `view`; call via
    /// `eth_call` (staticcall) off-chain.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amount The amount of `tokenIn` to quote.
    /// @return bestQuote The best `tokenOut` amount across all venues.
    /// @return venue The proprietary venue that produced `bestQuote`, or the
    /// Uniswap V3 SwapRouter02 address if the fallback won.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 bestQuote, address venue);

    /// @notice Quotes `amount` of `tokenIn` against a single venue — a whitelisted
    /// proprietary AMM or the public-venue fallback.
    /// @dev Not `view`; call via `eth_call` (staticcall) off-chain. Reverts
    /// `UnknownVenue` if `venue` is neither a whitelisted proprietary AMM nor the
    /// fallback address, and bubbles up any revert from the underlying venue.
    /// @param venue The venue to quote against — a proprietary AMM, or the
    /// fallback address for the public venue.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amount The amount of `tokenIn` to quote.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 amountOut);
}
