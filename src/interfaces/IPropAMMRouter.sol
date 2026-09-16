// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMRouter
/// @notice Router for single-hop swaps across whitelisted proprietary venues,
/// with a public-venue fallback used when the chosen propAMM cannot fill.
interface IPropAMMRouter {
    /// @notice Emitted once per successful swap after `tokenOut` is delivered to `recipient`.
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

    /// @notice Emitted when a frontend fee is skimmed from a `*WithFeeV1` swap output.
    /// @param feeRecipient The address that received the fee.
    /// @param tokenOut The output token the fee was taken in.
    /// @param feeAmount The fee amount transferred to `feeRecipient`.
    /// @param payer The account that invoked the swap and bore the fee.
    event FrontendFeeCharged(
        address indexed feeRecipient, address indexed tokenOut, uint256 feeAmount, address indexed payer
    );

    /// @notice Fee parameters for the `*WithFeeV1` entrypoints.
    /// @param bps Fee in basis points (1/10_000 of the output). Routers implementations
    /// may put a cap for this value.
    /// @param recipient Address that receives the fee in `tokenOut`. Must be non-zero.
    struct FrontendFee {
        uint16 bps;
        address recipient;
    }

    /// @notice Swaps an exact `amountIn` of `tokenIn` for as much `tokenOut` as
    /// possible, routing through the best-quoting venue and falling back to the
    /// public-venue fallback if the chosen venue fails to fill.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`. Only the propAMMs
    /// are quoted for selection (quoting the fallback on-chain costs gas), so the
    /// fallback is picked only when no propAMM can be priced or the best one is
    /// below `amountOutMin`.
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
    ) external payable returns (uint256 amountOut, address executedVenue);

    /// @notice Best-venue swap that skims a frontend fee from the output token.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`. Only the propAMMs
    /// are quoted for selection (quoting the fallback on-chain costs gas), so the
    /// fallback is picked only when no propAMM can be priced or the best one is
    /// below the grossed-up `amountOutMin`.
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
    ) external payable returns (uint256 amountOut, address executedVenue);

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
    /// @return executedVenue The venue that filled, or the fallback venue address.
    function swapViaVenueV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut, address executedVenue);

    /// @notice Caller-named-venue swap that skims a frontend fee from the output token.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`.
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
    ) external payable returns (uint256 amountOut);

    /// @notice Swaps an exact `amountIn` of `tokenIn` routing through the
    /// best-quoting venue among a caller-selected set, instead of all available
    /// venues. An on-chain requote across `venues` selects the best.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Venues that revert while quoting (including non-whitelisted
    /// addresses) are skipped. The public-venue fallback still applies as the
    /// transparent safety net if the chosen proprietary venue fails to fill.
    /// Reverts if neither venue nor the fallback can deliver `amountOutMin`.
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
    ) external payable returns (uint256 amountOut, address executedVenue);

    /// @notice Best-of-a-subset swap that skims a frontend fee from the output token.
    /// @dev The caller must approve this contract for at least `amountIn` of
    /// `tokenIn`. Reverts if the output is below `amountOutMin`.
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
    ) external payable returns (uint256 amountOut, address executedVenue);

    /// @notice Quotes `amount` of `tokenIn` across every venue and returns the
    /// best output and the venue that produced it.
    /// @dev Unlike `swapV1`, this includes the fallback, so `venue` is the price to
    /// beat rather than the venue `swapV1` would pick.
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
    /// fallback address.
    /// @param venue The venue to quote against — a propAMM address, or the
    /// fallback address for the public venue.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amount The amount of `tokenIn` to quote.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    /// @return quotedVenue The asked venue. Kept for retro-compatibility.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 amountOut, address quotedVenue);

    /// @notice Quotes `amountIn` of `tokenIn` across a caller-selected set of
    /// venues and returns the best output and the venue that produced it.
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

    /// @notice Splits one exact-input swap across whitelisted propAMM venues,
    /// planning the split ONCHAIN in this same transaction.
    /// @dev Takes exactly the same arguments as `swapV1`. It returns only
    /// `amountOut` — a split has no single executing venue, so there is nothing
    /// to name.
    ///
    /// The router probes every whitelisted venue for capacity (one call if the
    /// venue implements `IPropAMMFillable`, else a bounded quote probe), ranks
    /// what it finds against a Uniswap V3 reference quote, places up to
    /// `MAX_LEGS` propAMM legs and sends any remainder to Uniswap.
    ///
    /// A leg that fails at execution time has its input ABSORBED into that
    /// Uniswap remainder, which is floored only by the aggregate shortfall
    /// against `amountOutMin`. That shortfall is zero whenever the propAMM legs
    /// that succeeded already clear `amountOutMin` — the normal outcome of
    /// splitting into better-than-Uniswap venues — so the merged slice is
    /// MEV-exposed in the common case. The user can never receive less than
    /// `amountOutMin`, so the loss is bounded by their own stated tolerance,
    /// but `amountOutMin` is the ONLY lever here and should be set tight.
    ///
    /// Reverts `TooManyVenues` once the whitelist exceeds `MAX_SPLIT_VENUES`;
    /// check `isSplitAvailable()` before listing a venue. An EMPTY whitelist is
    /// not an error — it routes the whole order through Uniswap V3.
    /// @param tokenIn The token being sold (or the ETH sentinel).
    /// @param tokenOut The token being bought (or the ETH sentinel).
    /// @param amountIn The exact input to split. Bounded to `type(uint128).max`.
    /// @param amountOutMin The minimum TOTAL `tokenOut` across every leg.
    /// @param recipient The address that receives `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The total `tokenOut` delivered to `recipient`.
    function swapSplitV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    /// @notice `swapSplitV1` with a frontend fee skimmed from the output token.
    /// @dev `amountOutMin` is a NET minimum — what the user must be left with
    /// AFTER the fee — and is grossed up by `fee.bps` before planning, so the
    /// legs' floors and the aggregate check all sit on one basis. The returned
    /// `amountOut` and the per-leg `Swapped` events report GROSS amounts; net
    /// user output is `SUM(Swapped.amountOut) − FrontendFeeCharged.feeAmount`.
    /// @param fee The frontend fee (bps capped at `MAX_FEE_BPS`, plus recipient).
    /// @return amountOut The NET `tokenOut` delivered to `recipient`.
    function swapSplitWithFeeV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external payable returns (uint256 amountOut);
}
