// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Thrown when `_dispatchVenue` is called by anyone other than this
/// contract itself, i.e. outside of the `try`-wrapped self-call made by
/// `_coreSwap`.
error OnlySelf();
/// @notice Thrown when `venue` is not one of the whitelisted proprietary AMMs.
error UnknownVenue();
/// @notice Thrown when a swap's `tokenOut` output would be below the caller's
/// `amountOutMin`. Raised both *before* execution (the best venue quote is
/// already under the minimum, so the swap is rejected before any funds are
/// pulled) and *after* execution (the amount delivered to `recipient`,
/// measured as a balance delta against the pre-swap snapshot, falls short).
/// @param expectedAmount The minimum acceptable amount of `tokenOut` (the
/// caller's `amountOutMin`, grossed up for any frontend fee).
/// @param receivedAmount The amount that fell short: the best venue quote for
/// the pre-execution check, or the delivered balance delta post-execution.
error InsufficientOutput(uint256 expectedAmount, uint256 receivedAmount);
/// @notice Thrown when a swap is invoked after its `deadline`.
error Expired();
/// @notice Thrown when no venue can produce a quote for the requested pair
/// and amount.
error NoQuotesAvailable();
/// @notice Thrown when `tokenOut` balance decreases after a swap.
error TokenOutBalanceDecreased();
/// @notice Thrown when a fallback fee is invalid.
error InvalidFallbackFee(uint24 fee);
/// @notice Thrown when an address argument that must be non-zero is zero.
error ZeroAddress();
/// @notice Thrown when `setPairFees` is given arrays of unequal length.
error ArrayLengthMismatch();
/// @notice Thrown when `addVenue` is given a venue already on the whitelist.
error VenueAlreadyWhitelisted(address venue);
/// @notice Thrown when `removeVenue` is given a venue not on the whitelist.
error VenueNotWhitelisted(address venue);
/// @notice Thrown when the attached `msg.value` does not match what the
/// swap requires.
/// @param expected The required `msg.value`.
/// @param received The actual `msg.value` sent with the call.
error InvalidValue(uint256 expected, uint256 received);
/// @notice Thrown when forwarding native ETH to the swap `recipient` fails.
error ETHTransferFailed();
/// @notice Thrown when a non-WETH address sends ETH directly to the router.
error UnexpectedETHSender();
/// @notice Thrown when a swap's input and output resolve to the same token
/// (including `ETH_SENTINEL` against `WETH`), which no venue can fill.
error IdenticalTokens();
/// @notice Thrown when a multileg call supplies zero legs or more than
/// `MAX_SPLIT_VENUES` legs.
error InvalidLegCount(uint256 count);
/// @notice Thrown when an amount that must be non-zero is zero (a leg's
/// `amountIn`, or a splitter's `amountIn`).
error ZeroAmount();
/// @notice Thrown when `swapSplitV1`'s `amountIn` exceeds `type(uint128).max`,
/// the bound that keeps the planner's cross-multiplied rate comparisons
/// overflow-free.
error AmountTooLarge(uint256 amount);
/// @notice Thrown when the resolved venue set for a split exceeds
/// `MAX_SPLIT_VENUES` (including "empty venues = whole whitelist" when the
/// whitelist has grown past the bound — set order is unstable, so silent
/// truncation would be nondeterministic).
error TooManyVenues(uint256 count);
/// @notice Thrown when the router's `tokenIn` balance after the split quote
/// phase differs from the post-pull snapshot — some venue's quote consumed
/// in-flight user funds (R1 invariant, see the design spec).
error QuoteBalanceInvariantViolated();
/// @notice Thrown when a split's `maxLegs` bound is zero. Distinct from
/// `InvalidLegCount`, which bounds the number of legs actually supplied to a
/// multileg call.
error InvalidMaxLegs(uint256 maxLegs);
