// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMRouter
/// @notice Router for single-hop swaps across whitelisted proprietary venues,
/// with a public-venue baseline that also serves as the fallback when the
/// chosen proprietary venue cannot fill.
/// @dev A venue is either a whitelisted proprietary AMM address or `address(0)`,
/// which denotes the public-venue baseline/fallback. The quote/swap functions
/// may return `address(0)` to signal the baseline; the per-venue functions
/// accept only non-zero whitelisted addresses. Any non-zero venue returned by
/// `quoteV1` is accepted by `swapViaVenueV1`; route an `address(0)` result
/// through `swapV1` instead.
interface IPropAMMRouter {
    /// @notice Swaps an exact `amountIn` of `tokenIn` for as much `tokenOut` as
    /// possible, routing through the best-quoting venue and falling back to the
    /// public-venue baseline if the chosen proprietary venue fails to fill.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that receives `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    /// @return executedVenue The proprietary venue that filled the swap, or
    /// `address(0)` when the baseline fallback ran.
    function swapV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut, address executedVenue);

    /// @notice Swaps an exact `amountIn` of `tokenIn` through a caller-specified
    /// proprietary venue, falling back to the public-venue baseline if it fails.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts `UnknownVenue` if `venue` is not whitelisted, or
    /// reverts if the output is below `amountOutMin`. `venue` must be non-zero;
    /// use `swapV1` to reach the baseline directly.
    /// @param venue The proprietary venue to attempt first.
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
    /// @return venue The proprietary venue that produced `bestQuote`, or
    /// `address(0)` if the baseline won.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 bestQuote, address venue);

    /// @notice Quotes `amount` of `tokenIn` against a single whitelisted
    /// proprietary venue.
    /// @dev Not `view`; call via `eth_call` (staticcall) off-chain. Reverts
    /// `UnknownVenue` if `venue` is not whitelisted, and bubbles up any revert
    /// from the underlying venue.
    /// @param venue The proprietary venue to quote against.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amount The amount of `tokenIn` to quote.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 amountOut);
}
