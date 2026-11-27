// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../../src/PropAMMRouter.sol";
import {SplitPlanner} from "../../src/libraries/SplitPlanner.sol";
import {SymUniswap} from "./mocks/SymUniswap.sol";
import {PlannerHarness} from "./mocks/PlannerHarness.sol";

/// @title The split planner, on its own: many candidates at once
/// @notice The router-level checks (`SplitNoRegret`, `SplitCustody`) run with
/// ONE venue, because the whole router with two does not finish. The planning
/// step is where several venues interact, so it is checked here directly, on
/// the router's real code (`PlannerHarness` only exposes it), with up to
/// `MAX_LEGS + 1` arbitrary candidates.
///
/// `_waterfall`, for ANY candidates in ANY order and any `amountIn`, returns
/// legs such that:
///   W1  they spend exactly `amountIn` (what `_executeLegs` requires);
///   W2  there are at most `MAX_LEGS` venue legs, then at most one Uniswap
///       leg, last, with a positive input and `minOut == 0`;
///   W3  venue leg i is candidate i — the waterfall never skips a candidate
///       to place a later one — with an input in (0, fill] and
///       `minOut == proRataMin(out, fill, input)`;
///   W4  only the LAST venue leg can be partial, and a partial leg leaves no
///       Uniswap leg (it took everything that was left);
///   W5  every venue leg beat a Uniswap reference quote taken at a size in
///       [1, amountIn]: out * s > U(s) * fill. This is certificate fact C1 of
///       `SplitNoRegret` for its planning half, now for many legs.
///
/// `sortByRateDesc` returns a permutation of its input (nothing lost,
/// duplicated or altered) ordered by rate out/fill, highest first, ties broken
/// by the larger fill. The order is restated in the test (`_rankedAtLeast`),
/// not borrowed from `SplitPlanner.betterThan`, so a broken comparator fails.
///
/// `proRataMin` is the exact pro-rata share rounded DOWN: never more than the
/// venue's quote supports, never a full wei less; exact for a full leg; and
/// monotone in the leg size.
///
/// Candidates satisfy what `_gatherCandidates` guarantees: distinct venues,
/// 0 < fill <= amountIn, 0 < out <= uint128.max. Uniswap reference outputs are
/// assumed <= uint128.max (assumption (c) of `SplitNoRegret`).
contract SplitPlannerHalmos is Test, SymTest {
    PlannerHarness internal planner;
    SymUniswap internal uni;

    uint256 internal constant MAX = type(uint128).max;
    address internal constant TIN = address(0x1111);
    address internal constant TOUT = address(0x2222);

    function setUp() public {
        uni = new SymUniswap();
        AccessManager manager = new AccessManager(address(this));
        PlannerHarness impl = new PlannerHarness();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(uni), address(manager)));
        planner = PlannerHarness(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    //-----------//
    // Waterfall //
    //-----------//

    // Shape (W1-W4) and gate (W5) are separate checks: they stress the solver
    // differently (linear sums vs. products of symbolic prices), and a slow
    // query in one should not hide the result of the other.

    function check_waterfall_shape_1(uint256 amountIn) public {
        _checkWaterfall(1, amountIn, true, false);
    }

    function check_waterfall_shape_2(uint256 amountIn) public {
        _checkWaterfall(2, amountIn, true, false);
    }

    function check_waterfall_shape_3(uint256 amountIn) public {
        _checkWaterfall(3, amountIn, true, false);
    }

    /// @dev One more candidate than `MAX_LEGS`, so the leg cap is exercised.
    function check_waterfall_shape_6(uint256 amountIn) public {
        _checkWaterfall(6, amountIn, true, false);
    }

    /// @dev The gate checks stop at two candidates: with three, a query on the
    /// products of symbolic prices runs past 10 minutes. Two is enough to reach
    /// every state the gate can be in (initial reference, a contested candidate
    /// that triggers the one refinement, a candidate placed after it), and
    /// whether leg i passed depends only on candidate i and the reference
    /// current at that moment, never on how many candidates came before it.
    function check_waterfall_gate_1(uint256 amountIn) public {
        _checkWaterfall(1, amountIn, false, true);
    }

    /// @custom:halmos --solver-timeout-assertion 600000
    function check_waterfall_gate_2(uint256 amountIn) public {
        _checkWaterfall(2, amountIn, false, true);
    }

    function _checkWaterfall(uint256 n, uint256 a, bool shape, bool gate) internal {
        vm.assume(a > 0 && a <= MAX);
        SplitPlanner.Candidate[] memory c = _candidates(n, a);

        PropAMMRouter.Leg[] memory legs = planner.waterfall(c, TIN, TOUT, a);

        for (uint256 j = 0; j < uni.sampleCount(); j++) {
            vm.assume(uni.outs(j) <= MAX);
        }

        uint256 venueLegs = legs.length;
        if (venueLegs > 0 && legs[venueLegs - 1].venue == planner.fallbackSwapRouter()) venueLegs--;

        if (gate) {
            for (uint256 i = 0; i < venueLegs; i++) {
                assertTrue(_beatsSomeReference(c[i], a), "W5: venue leg without a winning reference");
            }
        }
        if (!shape) return;

        assertLe(venueLegs, planner.MAX_LEGS(), "W2: more than MAX_LEGS venue legs");
        assertLe(venueLegs, n, "W2: more venue legs than candidates");
        assertGe(legs.length, 1, "W1: no legs");

        uint256 sum;
        for (uint256 i = 0; i < legs.length; i++) {
            sum += legs[i].amountIn;
            if (i >= venueLegs) {
                // The Uniswap leg (W2).
                assertGt(legs[i].amountIn, 0, "W2: empty Uniswap leg");
                assertEq(legs[i].minOut, 0, "W2: Uniswap leg has a floor");
                continue;
            }
            // Venue leg i is candidate i (W3).
            assertEq(legs[i].venue, c[i].venue, "W3: venue leg out of candidate order");
            assertGt(legs[i].amountIn, 0, "W3: empty venue leg");
            assertLe(legs[i].amountIn, c[i].fill, "W3: venue leg above its fill");
            assertEq(
                legs[i].minOut,
                SplitPlanner.proRataMin(c[i].out, c[i].fill, legs[i].amountIn),
                "W3: minOut is not the pro-rata floor"
            );
            if (legs[i].amountIn < c[i].fill) {
                assertEq(i + 1, venueLegs, "W4: partial venue leg is not the last");
                assertEq(legs.length, venueLegs, "W4: Uniswap leg after a partial leg");
            }
        }
        assertEq(sum, a, "W1: legs do not spend exactly amountIn");
    }

    /// @dev Branch-free existential over the sampled reference points, so the
    /// whole search is ONE formula instead of a path per sample.
    function _beatsSomeReference(SplitPlanner.Candidate memory cand, uint256 a) internal view returns (bool found) {
        for (uint256 j = 0; j < uni.sampleCount(); j++) {
            uint256 s = uni.sizes(j);
            uint256 q = uni.outs(j);
            bool sizeOk = _and(s > 0, s <= a);
            uint256 sSafe = sizeOk ? s : 0;
            found = _or(found, _and(sizeOk, cand.out * sSafe > q * cand.fill));
        }
    }

    //------//
    // Sort //
    //------//

    function check_sort_2() public {
        _checkSort(2);
    }

    function check_sort_3() public {
        _checkSort(3);
    }

    function check_sort_4() public {
        _checkSort(4);
    }

    function _checkSort(uint256 n) internal {
        SplitPlanner.Candidate[] memory input = _candidates(n, MAX);
        // An external call: `input` is ABI-copied, so the sort cannot alias it.
        SplitPlanner.Candidate[] memory c = planner.sortByRateDesc(input);

        assertEq(c.length, n, "S: length changed");
        for (uint256 i = 0; i < n; i++) {
            // Each output is an input, unaltered...
            bool matched;
            for (uint256 j = 0; j < n; j++) {
                matched = _or(
                    matched,
                    _and(c[i].venue == input[j].venue, _and(c[i].fill == input[j].fill, c[i].out == input[j].out))
                );
            }
            assertTrue(matched, "S: output candidate not in the input");
            // ...and no two outputs are the same input (venues are distinct).
            for (uint256 k = i + 1; k < n; k++) {
                assertTrue(c[i].venue != c[k].venue, "S: candidate duplicated");
            }
            if (i + 1 < n) {
                assertTrue(_rankedAtLeast(c[i], c[i + 1]), "S: not sorted by rate");
            }
        }
    }

    /// @dev The order the sort must produce, written out here rather than
    /// taken from `SplitPlanner.betterThan`: a check that reused the library's
    /// comparator would accept any comparator, including a reversed one.
    /// x ranks at least as high as y when its rate out/fill is higher, or the
    /// rates tie and its fill is at least as large.
    function _rankedAtLeast(SplitPlanner.Candidate memory x, SplitPlanner.Candidate memory y)
        internal
        pure
        returns (bool)
    {
        uint256 lhs = x.out * y.fill;
        uint256 rhs = y.out * x.fill;
        return _or(lhs > rhs, _and(lhs == rhs, x.fill >= y.fill));
    }

    //------------//
    // proRataMin //
    //------------//

    /// @dev Only the full-leg case is proven here. The rest — the floor is
    /// never above the exact share, is less than one wei below it, and is
    /// monotone in the leg — are facts about floor division that bit-vector
    /// solvers do not close (each timed out at 300 s; so does Solidity's own
    /// overflow check on `out * leg`, which compiles to a division). They are
    /// proven over the integers in `no_regret_lemma.py` (lemma D). That proof
    /// applies because `out * leg` cannot overflow where the router calls it:
    /// `out <= uint128.max` (`_gatherCandidates`) and `leg <= fill <=
    /// amountIn <= uint128.max` (`_validateSplitParams`), so the product is
    /// below 2^256, and EVM `DIV` on it IS floor division.
    function check_proRataMin_fullLegIsQuote(uint256 out, uint256 fill) public pure {
        _assumeRange(out, fill, fill);
        assertEq(SplitPlanner.proRataMin(out, fill, fill), out, "P: full leg floor is not the quote");
    }

    function _assumeRange(uint256 out, uint256 fill, uint256 leg) internal pure {
        vm.assume(fill > 0 && fill <= MAX && out <= MAX && leg <= fill);
    }

    //---------//
    // Helpers //
    //---------//

    /// @dev `n` symbolic candidates as `_gatherCandidates` would emit them for
    /// an order of `a`: distinct venues, 0 < fill <= a, 0 < out <= uint128.max.
    function _candidates(uint256 n, uint256 a) internal returns (SplitPlanner.Candidate[] memory c) {
        c = new SplitPlanner.Candidate[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 fill = svm.createUint256("fill");
            uint256 out = svm.createUint256("out");
            vm.assume(fill > 0 && fill <= a);
            vm.assume(out > 0 && out <= MAX);
            c[i] = SplitPlanner.Candidate({venue: address(uint160(0x1000 + i)), fill: fill, out: out});
        }
    }

    function _and(bool x, bool y) internal pure returns (bool r) {
        assembly {
            r := and(x, y)
        }
    }

    function _or(bool x, bool y) internal pure returns (bool r) {
        assembly {
            r := or(x, y)
        }
    }
}
