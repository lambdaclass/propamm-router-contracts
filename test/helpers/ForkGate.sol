// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";

/// @notice Shared entry gate for fork tests.
///
/// Fork suites need a live RPC that CI does not have. The two failure modes
/// this exists to prevent, both of which this repo has had:
///  - `vm.envString("RPC_URL")` with no fallback REVERTS `setUp`, so a bare
///    `forge test` reports a red suite for a missing credential rather than an
///    absent capability;
///  - a hardcoded public endpoint as the `vm.envOr` default silently sends
///    every `forge test` to a third party and pays fork latency for it.
///
/// The gate does neither: no RPC means the suite SKIPS, and supplying
/// `RPC_URL` runs it with no file edit. Fork suites should also carry a `Fork`
/// suffix so `--no-match-path '*Fork*'` excludes them.
abstract contract ForkGate is Test {
    /// @dev Selects a fork from `RPC_URL`, or skips the suite if it is unset.
    /// Call FIRST in `setUp`. `vm.skip` marks the suite skipped but does not
    /// halt execution, so it returns a bool for callers that must not run
    /// their remaining setup against a non-forked chain.
    /// @return forked True when a fork was selected and setup should continue.
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
