// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Emitted when an authorized account updates the fallback venue fee.
/// @param oldFee The previous `fallbackFee`.
/// @param newFee The new `fallbackFee`.
event FallbackFeeUpdated(uint24 oldFee, uint24 newFee);
/// @notice Emitted when an authorized account updates the fallback venue address.
/// @param oldRouter The previous `fallbackSwapRouter`.
/// @param newRouter The new `fallbackSwapRouter`.
event FallbackSwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
/// @notice Emitted when an authorized account updates the fallback quoter address.
/// @param oldQuoter The previous `fallbackQuoter`.
/// @param newQuoter The new `fallbackQuoter`.
event FallbackQuoterUpdated(address indexed oldQuoter, address indexed newQuoter);
/// @notice Emitted when an authorized account sets or clears a per-pair fallback fee.
/// @param tokenA One token of the pair (as supplied to the setter).
/// @param tokenB The other token of the pair (as supplied to the setter).
/// @param oldFee The previous override (0 if it was unset).
/// @param newFee The new override (0 means cleared / use global default).
event PairFeeUpdated(address indexed tokenA, address indexed tokenB, uint24 oldFee, uint24 newFee);
/// @notice Emitted when an authorized account rescues tokens stranded on the router.
/// @param token The ERC-20 rescued.
/// @param to The recipient of the rescued tokens.
/// @param amount The amount transferred.
event TokensRescued(address indexed token, address indexed to, uint256 amount);
/// @notice Emitted when a propAMM venue is added to the whitelist via
/// `addVenue`. `initialize` seeds no venues, so the whitelist starts empty.
/// @param venue The venue address added.
event VenueWhitelisted(address indexed venue);
/// @notice Emitted when an authorized account removes a propAMM venue from the whitelist.
/// @param venue The venue address removed.
event VenueRemoved(address indexed venue);

/// @notice Emitted when a venue call reverted and the swap fell back to Uniswap V3.
/// @dev The router catches that revert and fills on Uniswap, so the transaction
///      succeeds and the only trace of the failure is the call tree — which a node
///      can only serve for as long as it keeps the state to re-execute from (128
///      blocks on ethrex). This event puts the same facts in a log, where they are
///      replayable forever. It is emitted once per failed venue, so a swap that
///      tries several produces several.
/// @param venue The venue whose call reverted.
/// @param tokenIn The input token of the attempt.
/// @param tokenOut The output token of the attempt.
/// @param amountIn The input amount the venue was asked to fill.
/// @param entrySelector The router entrypoint the caller used, which says whether the
///        caller pinned this venue (`swapViaVenueV1`) or the router chose it (`swapV1`).
/// @param reason The venue's revert data, truncated to `VENUE_REVERT_LOG_BYTES`: enough
///        for a 4-byte custom error selector or a short `Error(string)`.
event VenueCallFailed(
    address indexed venue,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    bytes4 entrySelector,
    bytes reason
);
