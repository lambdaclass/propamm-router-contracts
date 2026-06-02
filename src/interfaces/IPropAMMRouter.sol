// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMRouter
/// @notice Router for single-hop swaps across whitelisted proprietary venues,
/// with a public-venue fallback used when the chosen propAMM cannot fill.
/// @dev A venue is either a whitelisted propAMM address or the public-venue fallback.
interface IPropAMMRouter {
    /// @notice Emitted once per successful swap (via `swapV1`, `swapViaVenueV1`,
    /// `swapViaSelectedVenuesV1`) after `tokenOut` is delivered to `recipient`.
    /// @param sender The address that invoked the swap entrypoint and supplied
    /// `amountIn` of `tokenIn`. Indexed so consumers can fetch a given account's
    /// recent swaps.
    /// @param tokenIn The token sold.
    /// @param tokenOut The token bought.
    /// @param amountIn The exact amount of `tokenIn` pulled from `sender`.
    /// @param amountOut The amount of `tokenOut` delivered to `recipient`,
    /// measured as a balance delta.
    /// @param recipient The address that received `tokenOut`.
    /// @param marketMaker The proprietary AMM that filled, or the public-venue
    /// fallback address.
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient,
        address marketMaker
    );

    /// @notice Fee parameters for the `*WithFeeV1` entrypoints. Bundled into a struct
    /// so each entrypoint stays within the EVM stack limit without enabling `via_ir`.
    /// @param bps Fee in basis points (1/10_000 of the output). Must be <= `MAX_FEE_BPS`.
    /// @param recipient Address that receives the fee in `tokenOut`. Must be non-zero.
    struct FrontendFee {
        uint16 bps;
        address recipient;
    }
    
    /// @notice Swaps an exact `amountIn` of `tokenIn` for as much `tokenOut` as
    /// possible, routing through the best-quoting venue and falling back to the
    /// public-venue fallback if the chosen venue fails to fill.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that receives `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    /// @return executedVenue The venue that filled the swap, or the fallback venue address.
    function swapV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut, address executedVenue);

    /// @notice Best-venue swap that skims a frontend fee from the output token.
    /// @dev Implementation-only (not in `IPropAMMRouter`). Validates `fee`, grosses up
    /// the net `amountOutMin` so the user still nets at least their minimum, routes the
    /// swap to this contract, then forwards the fee and the net. Emits `Swapped` with the
    /// net amount and the real `recipient`. `whenNotPaused`/`nonReentrant` like `swapV1`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum NET `tokenOut` the user must receive (after the fee).
    /// @param recipient The address that receives the net `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @param fee The frontend fee (bps + recipient).
    /// @return amountOut The net `tokenOut` delivered to `recipient`.
    /// @return executedVenue The venue that filled, or the fallback venue address.
    function swapWithFeeV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external returns (uint256 amountOut, address executedVenue);
    
    /// @notice Swaps an exact `amountIn` of `tokenIn` through a caller-specified
    /// venue, falling back to the public venue if it fails.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts `UnknownVenue` if `venue` is neither a whitelisted
    /// propAMM nor the fallback address, or reverts if the output is
    /// below `amountOutMin`. Naming the fallback address routes directly to the
    /// public venue with no further fallback (it is the fallback).
    /// @param venue The venue address.
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

    /// @notice Caller-named-venue swap that skims a frontend fee from the output token.
    /// @dev Implementation-only. Like `swapViaVenueV1` plus the fee skim; the underlying
    /// swap is routed to this contract, then fee + net are forwarded. Reverts `UnknownVenue`
    /// if `venue` is neither a whitelisted propAMM nor the fallback address.
    /// @param venue The venue address (propAMM or the fallback router address).
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum NET `tokenOut` the user must receive (after the fee).
    /// @param recipient The address that receives the net `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @param fee The frontend fee (bps + recipient).
    /// @return amountOut The net `tokenOut` delivered to `recipient`.
    function swapViaVenueWithFeeV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external returns (uint256 amountOut);

    /// @notice Swaps an exact `amountIn` of `tokenIn` routing through the
    /// best-quoting venue among a caller-selected set, instead of all available
    /// venues. An on-chain requote across `venues` selects the best.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Venues that revert while quoting (including non-whitelisted
    /// addresses) are skipped. The public-venue fallback still applies as the
    /// transparent safety net if the chosen proprietary venue fails to fill.
    /// Reverts only if even the public-venue fallback cannot deliver `amountOutMin`.
    /// @param venues The venues to consider — a subset of the available venues.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that receives `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    /// @return executedVenue The venue that filled the swap, or the public-venue
    /// fallback address when the fallback ran.
    function swapViaSelectedVenuesV1(
        address[] calldata venues,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut, address executedVenue);
    
    /// @notice Best-of-a-subset swap that skims a frontend fee from the output token.
    /// @dev Implementation-only. Like `swapViaSelectedVenuesV1` plus the fee skim; requotes
    /// only `venues`, grosses up the net min, routes the swap to this contract, then forwards
    /// fee + net. Reverts `NoQuotesAvailable` if none of `venues` can be priced.
    /// @param venues The venues to consider — a subset of the available venues.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum NET `tokenOut` the user must receive (after the fee).
    /// @param recipient The address that receives the net `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @param fee The frontend fee (bps + recipient).
    /// @return amountOut The net `tokenOut` delivered to `recipient`.
    /// @return executedVenue The venue that filled, or the fallback venue address.
    function swapViaSelectedVenuesWithFeeV1(
        address[] calldata venues,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external returns (uint256 amountOut, address executedVenue);

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
    /// the fallback venue address if the fallback won.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 bestQuote, address venue);

    /// @notice Quotes `amount` of `tokenIn` against a single venue — a whitelisted
    /// propAMM or the public-venue fallback.
    /// @dev Reverts `UnknownVenue` if `venue` is neither a whitelisted propAMM nor the
    /// fallback address, and bubbles up any revert from the underlying venue.
    /// @param venue The venue to quote against — a propAMM address, or the
    /// fallback address for the public venue.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amount The amount of `tokenIn` to quote.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 amountOut);

    /// @notice Quotes `amountIn` of `tokenIn` across a caller-selected set of
    /// venues and returns the best output and the venue that produced it.
    /// @dev Considers ONLY `venues` (not all available venues). Venues that
    /// revert while quoting — including non-whitelisted addresses — are skipped.
    /// Reverts `NoQuotesAvailable` if none of `venues` can be priced.
    /// @param venues The venues to consider — a subset of the available venues.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The amount of `tokenIn` to quote.
    /// @return bestAmountOut The best `tokenOut` amount across `venues`.
    /// @return bestVenue The venue that produced `bestAmountOut`.
    function quoteSelectedVenuesV1(address[] calldata venues, address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 bestAmountOut, address bestVenue);
}
