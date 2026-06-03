// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the PrioUpdateRegistry that stores the packed pricing state some
// proprietary AMMs read at swap time. A venue prices a swap by reading its lane
// via `getState`; if that lane is stale the swap reverts, so the lane must be
// (re)published with a fresh `updateState` before the swap.
address constant PRIO_UPDATE_REGISTRY =
    0xDa7AfeeD01fe625CF15d187a19f94B45f00b8C5F;

/// @title IPrioUpdateRegistry
/// @notice Minimal interface for the on-chain registry that holds the
/// timestamped pricing state proprietary AMMs read while quoting/swapping.
/// @dev Only the members the fork tests need are declared. State is scoped per
/// `target` and `laneIndex`; a `target` authorizes writers via `addUpdater`.
interface IPrioUpdateRegistry {
    /// @notice Authorizes `updater` to write state on behalf of `msg.sender`.
    /// @param updater The address being granted write authorization.
    function addUpdater(address updater) external;

    /// @notice Returns whether `updater` may write state for `target`.
    function isUpdater(
        address target,
        address updater
    ) external view returns (bool);

    /// @notice Writes a state update for `target` at `laneIndex`, with
    /// `msg.sender` acting as the (authorized) updater.
    /// @param target The address whose state is being updated.
    /// @param laneIndex The lane to write, scoped to `target`.
    /// @param updateTimestamp The timestamp associated with this update; must
    /// lie within the registry's accepted freshness window around
    /// `block.timestamp`.
    /// @param slots The packed slot values to write (slot 0 must fit in 27 bytes).
    function updateState(
        address target,
        uint256 laneIndex,
        uint32 updateTimestamp,
        uint256[] calldata slots
    ) external;
}
