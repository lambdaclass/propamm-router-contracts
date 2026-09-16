// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

/// @notice Shared entry gate for fork tests.
///
/// Two failure modes this exists to prevent, both of which this repo has had:
///  - `vm.envString("RPC_URL")` with no fallback REVERTS `setUp`, so a bare
///    `forge test` reports a red suite for a missing credential rather than an
///    absent capability;
///  - a hardcoded public endpoint as the `vm.envOr` default silently sends
///    every `forge test` to a third party and pays fork latency for it.
///
/// No RPC means the suite SKIPS; supplying `RPC_URL` runs it with no file edit.
/// Fork suites must also carry `Fork` in the filename so `--no-match-path
/// '*Fork*'` excludes them from the PR gate.
abstract contract ForkGate is Test {
    /// @dev Selects a fork from `RPC_URL`, or skips the suite if it is unset.
    /// Call FIRST in `setUp`. `vm.skip` marks the suite skipped but does not
    /// halt execution, so it returns a bool for callers that must not run their
    /// remaining setup against a non-forked chain.
    function _selectForkOrSkip() internal returns (bool forked) {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "fork test: set RPC_URL to run this suite");
            return false;
        }
        vm.createSelectFork(rpc);
        return true;
    }
}
