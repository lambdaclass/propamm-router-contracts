// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMRouter
/// @notice Interface for a router that executes single-hop swaps against a
/// proprietary AMM (FermiSwap, Kipseli, or Bebop) or a public-venue fallback
/// (Uniswap V3), with the public venue also serving as the recovery path when
/// the chosen proprietary AMM cannot fill the swap.
interface IPropAMMRouter {
    /// @notice Identifies which venue the caller wants to route through.
    /// @dev `Fallback` selects the public venue (Uniswap V3) directly,
    /// bypassing the proprietary AMMs. For the proprietary entries the
    /// implementation is still free to fall back to Uniswap V3 if the
    /// selected venue cannot fulfill the swap.
    enum Venue {
        Fallback,
        FermiSwap,
        Kipseli,
        Bebop
    }

    /// @notice Swaps an exact amount of `tokenIn` for as much `tokenOut` as
    /// possible by quoting every supported venue on-chain and routing through
    /// the one with the best quote, falling back to Uniswap V3 if the chosen
    /// proprietary venue reverts at execution time.
    /// @dev Calls `quote` first to pick the winning venue, then executes the
    /// swap on it. If the winner is `Venue.Fallback`, the swap goes directly
    /// to Uniswap V3. If the winning proprietary venue reverts during
    /// execution, the swap falls back to Uniswap V3 at `uniswapFee`.
    /// Ties on `bestQuote` resolve to the lowest enum value (i.e.
    /// `Venue.Fallback` wins a tie against any proprietary AMM).
    /// Reverts `NoQuotesAvailable` if no venue can produce a quote.
    /// The caller must have approved this contract to spend at least
    /// `amountIn` of `tokenIn`. Reverts if the final output is below
    /// `amountOutMin`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`; the swap
    /// reverts if the actual output is lower.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param uniswapFee The Uniswap V3 pool fee tier (in hundredths of a bip)
    /// used by both the fallback quote and the execution path when Uniswap V3
    /// wins or recovers; ignored by the proprietary AMM execution path.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` actually received by `recipient`.
    /// @return executedVenue The venue that actually filled the swap.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 uniswapFee,
        uint256 deadline
    ) external returns (uint256 amountOut, Venue executedVenue);

    /// @notice Swaps an exact amount of `tokenIn` for as much `tokenOut` as possible,
    /// routing first through the selected venue and falling back to the public
    /// venue if that route fails.
    /// @dev The caller must have approved this contract to spend at least `amountIn`
    /// of `tokenIn`. Reverts if the final output is below `amountOutMin`.
    /// @param venue The venue to attempt the swap on first; pass `Venue.Fallback`
    /// to skip the proprietary AMMs and go straight to Uniswap V3.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`; the swap
    /// reverts if the actual output is lower.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param uniswapFee The Uniswap V3 pool fee tier (in hundredths of a bip) used by
    /// the fallback route; ignored by the proprietary AMM path.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` actually received by `recipient`.
    function swapDirect(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 uniswapFee,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /// @notice Quotes `amount` of `tokenIn` against every supported venue
    /// (the proprietary AMMs and the Uniswap V3 fallback) and returns the
    /// best output along with the venue that produced it.
    /// @dev Venues that revert when quoting are skipped. Reverts if no venue
    /// can produce a quote. Not `view`: the Uniswap V3 QuoterV2 branch
    /// prices via revert-based simulation. Call this via `eth_call`
    /// (staticcall) from off-chain.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @param uniswapFee The Uniswap V3 pool fee tier used when quoting the
    /// `Venue.Fallback` branch; ignored by the proprietary AMM branches.
    /// @return quote The best `tokenOut` amount across all venues.
    /// @return venue The venue that produced `quote`.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint24 uniswapFee
    ) external returns (uint256 quote, Venue venue);

    /// @notice `quote` overload that uses the implementation's default
    /// Uniswap V3 fee tier (`DEFAULT_FALLBACK_FEE`) for the `Venue.Fallback`
    /// branch.
    /// @dev Convenience wrapper for callers that don't want to pick a fee
    /// tier. For pairs whose deepest pool is not at the default tier (e.g.
    /// USDC/WETH on mainnet, which is `500`), prefer the 4-arg overload.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return quote The best `tokenOut` amount across all venues.
    /// @return venue The venue that produced `quote`.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 quote, Venue venue);

    /// @notice Quotes `amount` of `tokenIn` against a single specified venue.
    /// Not `view`: the Uniswap V3 fallback branch prices via revert-based
    /// simulation, which is incompatible with `view`. Call this via
    /// `eth_call` (staticcall) from off-chain.
    ///
    /// Reverts `UnknownVenue` if `venue` is not a recognized enum value.
    /// Bubbles up any revert from the underlying venue (e.g. unsupported
    /// pair, no liquidity, stale Kipseli oracle).
    /// @param venue The venue to quote against.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @param uniswapFee The Uniswap V3 pool fee tier used when `venue` is
    /// `Venue.Fallback`; ignored by the proprietary AMM branches.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function quoteVenue(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint24 uniswapFee
    ) external returns (uint256 amountOut);

    /// @notice `quoteVenue` overload that uses the implementation's default
    /// Uniswap V3 fee tier (`DEFAULT_FALLBACK_FEE`) when `venue` is
    /// `Venue.Fallback`.
    /// @dev Convenience wrapper for callers that don't want to pick a fee
    /// tier. For pairs whose deepest pool is not at the default tier, prefer
    /// the 5-arg overload.
    /// @param venue The venue to quote against.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function quoteVenue(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 amountOut);
}
