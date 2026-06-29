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
/// @notice Thrown when `uniswapV3SwapCallback` is invoked by an address that is
/// not the canonical Uniswap V3 pool for the callback's `(tokenIn, tokenOut, fee)`.
/// Guards the callback, which would otherwise be a public `transferFrom` primitive.
error OnlyPool();
/// @notice Thrown when a swap's `amountIn` exceeds `int256` max and so cannot be
/// passed to the core pool's `swap` as a signed exact-input amount.
error AmountTooLarge();
/// @notice Thrown when the Uniswap V3 swap callback is owed more input than the
/// exact `amountIn` the swap specified — bounds the payer's allowance so a future
/// exact-output change (or pool edge case) can never over-pull.
error ExcessiveInput();
