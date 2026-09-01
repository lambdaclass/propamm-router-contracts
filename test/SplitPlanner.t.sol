// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SplitPlanner} from "../src/libraries/SplitPlanner.sol";

contract SplitPlannerTest is Test {
    function _cand(address v, uint256 fill, uint256 out) internal pure returns (SplitPlanner.Candidate memory) {
        return SplitPlanner.Candidate({venue: v, fill: fill, out: out});
    }

    function test_isSaturated_flatVenueIsNot() public pure {
        // Perfectly linear: out(full) == 2 * out(half).
        assertFalse(SplitPlanner.isSaturated(200e18, 100e18));
    }

    function test_isSaturated_withinToleranceIsNot() public pure {
        // 22bp in-cap drift (worst measured, Phase 0) must NOT flag.
        // out(full) = 2 * out(half) * (1 - 0.0022)
        assertFalse(SplitPlanner.isSaturated(199.56e18, 100e18));
    }

    function test_isSaturated_fermiPatternIs() public pure {
        // Phase 0 Fermi at 1M/500k: 288.12 vs 203.75 (ratio 1.41 << 2).
        assertTrue(SplitPlanner.isSaturated(288.12e18, 203.75e18));
    }

    function test_isSaturated_fullyFlatOutputIs() public pure {
        // out(full) == out(half): hard saturation (Kipseli pattern).
        assertTrue(SplitPlanner.isSaturated(100e18, 100e18));
    }

    function test_sortByRateDesc_ordersByRateThenFill() public pure {
        SplitPlanner.Candidate[] memory c = new SplitPlanner.Candidate[](3);
        c[0] = _cand(address(1), 100e18, 150e18); // rate 1.5
        c[1] = _cand(address(2), 100e18, 200e18); // rate 2.0
        c[2] = _cand(address(3), 200e18, 300e18); // rate 1.5, bigger fill
        SplitPlanner.sortByRateDesc(c);
        assertEq(c[0].venue, address(2)); // best rate first
        assertEq(c[1].venue, address(3)); // tie -> larger fill first
        assertEq(c[2].venue, address(1));
    }

    function test_proRataMin_fullLegReturnsQuote() public pure {
        assertEq(SplitPlanner.proRataMin(200e18, 100e18, 100e18), 200e18);
    }

    function test_proRataMin_partialLegFloors() public pure {
        // out=200, fill=100, leg=33 -> floor(200*33/100) = 66
        assertEq(SplitPlanner.proRataMin(200, 100, 33), 66);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_proRataMin_neverExceedsLinearDelivery(uint128 price, uint128 fill, uint128 leg) public pure {
        // A linear venue quoting out = floor(fill * price / 1e18) and
        // delivering floor(leg * price / 1e18) must always meet the pro-rata min.
        fill = uint128(bound(uint256(fill), 1, type(uint128).max));
        leg = uint128(bound(uint256(leg), 1, uint256(fill)));
        // `price` is capped so `out` stays within uint128, matching the
        // router-enforced precondition documented on SplitPlanner (amounts
        // bounded to uint128 keep proRataMin's out*leg product inside
        // uint256). Without this cap, an unrealistically large price makes
        // `out` exceed uint128 and the multiplication in proRataMin
        // overflows for reasons unrelated to the property under test.
        price = uint128(bound(uint256(price), 0, uint256(type(uint128).max) * 1e18 / uint256(fill)));
        uint256 out = uint256(fill) * price / 1e18;
        uint256 delivery = uint256(leg) * price / 1e18;
        assertLe(SplitPlanner.proRataMin(out, fill, leg), delivery);
    }
}
