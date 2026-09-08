// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SampleStats} from "./helpers/SampleStats.sol";

/// @notice Unit coverage for the sampler statistics. Deliberately NOT a fork
/// suite: the arithmetic these fork samplers publish into the economics CSV
/// should be verifiable without an archive RPC.
contract SampleStatsTest is Test {
    /// @dev A block whose venue lane could not be recovered produces no
    /// measurement. Leaving a 0 in the sample slot and taking the median over
    /// the whole array reports "no data" as "zero depth" — and these values
    /// are harvested verbatim by `scripts/gas/split_economics.py` into the CSV
    /// that backs the README's economics claims.
    function test_medianIgnoresUnmeasuredSamples() public pure {
        uint256[] memory v = new uint256[](5);
        v[0] = 3_000_000e6;
        v[1] = 2_000_000e6;
        v[2] = 1_000_000e6;
        // v[3] and v[4] are blocks where the lane was unrecoverable.
        assertEq(SampleStats.median(v, 3), 2_000_000e6, "median must ignore the unmeasured tail");
    }

    function test_medianOfNoMeasurementsIsZero() public pure {
        uint256[] memory none = new uint256[](4);
        assertEq(SampleStats.median(none, 0), 0, "no measurements at all is the only honest zero");
    }

    function test_medianSortsAndTakesUpperMiddle() public pure {
        uint256[] memory v = new uint256[](3);
        (v[0], v[1], v[2]) = (5, 1, 3);
        assertEq(SampleStats.median(v, 3), 3, "unsorted input must still yield the middle sample");
    }
}
