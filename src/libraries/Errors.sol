// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Thrown when `_dispatchVenue` is called by anyone other than this
/// contract itself, i.e. outside of the `try`-wrapped self-call made by
/// `_coreSwap`.
error OnlySelf();
/// @notice Thrown when `venue` is not one of the whitelisted proprietary AMMs.
error UnknownVenue();
/// @notice Thrown when a swap cannot deliver at least `amountOutMin` of
/// `tokenOut` to `recipient`.
/// @param expectedAmount The minimum acceptable amount of `tokenOut` (i.e.
/// the caller's `amountOutMin`).
/// @param receivedAmount The actual amount of `tokenOut` delivered to
/// `recipient`, measured as a balance delta against the pre-swap snapshot.
error InsufficientOutput(uint256 expectedAmount, uint256 receivedAmount);
/// @notice Thrown by `swapV1` when the best quote across all venues is below
/// `amountOutMin`, rejecting the swap before any funds are pulled. Distinct
/// from `InsufficientOutput`, which signals a shortfall measured *after*
/// execution.
/// @param amountOutMin The caller's minimum acceptable amount of `tokenOut`.
/// @param bestQuote The best `tokenOut` amount any venue quoted.
error QuoteBelowMinimum(uint256 amountOutMin, uint256 bestQuote);
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
/// @notice Thrown when a requested frontend fee exceeds `MAX_FEE_BPS`.
/// @param requested The caller-supplied fee in basis points.
/// @param max The maximum allowed fee (`MAX_FEE_BPS`).
error FeeBpsTooHigh(uint16 requested, uint16 max);
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
