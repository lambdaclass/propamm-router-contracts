// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SplitPlanner} from "../src/libraries/SplitPlanner.sol";

contract SplitPlannerTest is Test {
    function _c(address v, uint256 fill, uint256 out) internal pure returns (SplitPlanner.Candidate memory) {
        return SplitPlanner.Candidate({venue: v, fill: fill, out: out});
    }

    // --- isSaturated --------------------------------------------------------

    /// @dev Perfectly linear: out(p) == 2*out(p/2). Not saturated.
    function test_isSaturated_linearIsNotSaturated() public pure {
        assertFalse(SplitPlanner.isSaturated(200e18, 100e18));
    }

    /// @dev Flat ceiling: out(p) == out(p/2). Strongly saturated.
    function test_isSaturated_flatIsSaturated() public pure {
        assertTrue(SplitPlanner.isSaturated(100e18, 100e18));
    }

    /// @dev Drift of 50bp is inside the 100bp tolerance band, so NOT saturated.
    /// 2 * 100e18 * (10000-100)/10000 = 198e18; outFull 199e18 > 198e18.
    function test_isSaturated_driftInsideToleranceIsNotSaturated() public pure {
        assertFalse(SplitPlanner.isSaturated(199e18, 100e18));
    }

    /// @dev Drift past the band. 197e18 < 198e18 => saturated.
    function test_isSaturated_driftPastToleranceIsSaturated() public pure {
        assertTrue(SplitPlanner.isSaturated(197e18, 100e18));
    }

    // --- betterThan / sortByRateDesc ----------------------------------------

    function test_betterThan_higherRateWins() public pure {
        // a: 1000 out per 1000 in (rate 1.0); b: 900 out per 1000 in (rate 0.9)
        assertTrue(SplitPlanner.betterThan(_c(address(1), 1000, 1000), _c(address(2), 1000, 900)));
    }

    /// @dev Equal rates tie-break toward the LARGER fill, so fewer legs are used.
    function test_betterThan_equalRateBreaksTowardLargerFill() public pure {
        assertTrue(SplitPlanner.betterThan(_c(address(1), 2000, 2000), _c(address(2), 1000, 1000)));
        assertFalse(SplitPlanner.betterThan(_c(address(2), 1000, 1000), _c(address(1), 2000, 2000)));
    }

    function test_sortByRateDesc_ordersDescending() public pure {
        SplitPlanner.Candidate[] memory c = new SplitPlanner.Candidate[](3);
        c[0] = _c(address(1), 1000, 900); // 0.90
        c[1] = _c(address(2), 1000, 1100); // 1.10
        c[2] = _c(address(3), 1000, 1000); // 1.00
        SplitPlanner.sortByRateDesc(c);
        assertEq(c[0].venue, address(2));
        assertEq(c[1].venue, address(3));
        assertEq(c[2].venue, address(1));
    }

    function test_sortByRateDesc_emptyAndSingleAreNoops() public pure {
        SplitPlanner.Candidate[] memory empty = new SplitPlanner.Candidate[](0);
        SplitPlanner.sortByRateDesc(empty);
        assertEq(empty.length, 0);

        SplitPlanner.Candidate[] memory one = new SplitPlanner.Candidate[](1);
        one[0] = _c(address(7), 5, 5);
        SplitPlanner.sortByRateDesc(one);
        assertEq(one[0].venue, address(7));
    }

    // --- proRataMin ---------------------------------------------------------

    /// @dev A leg equal to the quoted fill gets the whole quote, with no
    /// division rounding applied.
    function test_proRataMin_fullLegReturnsWholeQuote() public pure {
        assertEq(SplitPlanner.proRataMin(1000, 1000, 1000), 1000);
    }

    function test_proRataMin_partialLegIsFloored() public pure {
        // 3 out for 2 fill, leg of 1 => 3*1/2 = 1 (floored from 1.5)
        assertEq(SplitPlanner.proRataMin(3, 2, 1), 1);
    }

    function test_proRataMin_zeroLegIsZero() public pure {
        assertEq(SplitPlanner.proRataMin(1000, 1000, 0), 0);
    }
}
