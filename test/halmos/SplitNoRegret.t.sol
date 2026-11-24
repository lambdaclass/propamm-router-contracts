// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../../src/PropAMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SymUniswap} from "./mocks/SymUniswap.sol";
import {SymVenue} from "./mocks/SymVenue.sol";

/// @title No-regret property of `swapSplitV1`: the code half
/// @notice The property: a split never delivers less than sending the whole
/// order to the Uniswap fallback,
///
///     amountOut  >=  U(amountIn),
///
/// for EVERY behaviour of the whitelisted venues — or the call reverts, which
/// leaves the user whole. Assumed about Uniswap, and nothing else:
///   (a) the quoter reports what the swap pays and nothing moves the pool
///       mid-transaction — built into `SymUniswap` (one table for both);
///   (b) the average rate never improves with size: x <= y => U(x)/x >= U(y)/y.
///       Any concave curve through U(0) = 0 satisfies it;
///   (c) every Uniswap output the run sees fits in uint128. Past that the
///       router clamps a reference quote to zero, which waves every venue
///       through the gate (see `_waterfall`); 3.4e38 base units is far outside
///       any real pool.
///
/// The proof has two halves, because the arithmetic linking them is a chain of
/// products that bit-vector solvers cannot close (measured: Yices times out at
/// 300s on the direct `amountOut >= U(amountIn)` query, even with one venue):
///
///   1. HERE (Halmos, over the real router bytecode): every run that does not
///      revert satisfies a CERTIFICATE — facts about its legs, with no
///      assumption about Uniswap's prices beyond (a) and (c).
///   2. `no_regret_lemma.py` (Z3, unbounded integers): certificate + (b)
///      => amountOut >= U(amountIn). The certificate's facts are stated in
///      exactly that script's terms.
///
/// The certificate, for a run with amountIn = a:
///   C1  every venue leg that executed received l > 0 and delivered d, and has
///       a WITNESS: a quote (fill -> out) of that venue and a sampled Uniswap
///       point (s, q = U(s)) with
///           0 < s <= a,  fill > 0,  out*s > q*fill        (the gate)
///       and either  l == fill and d >= out                 (full leg)
///              or   l <  fill and d >= floor(out*l/fill)   (partial leg);
///   C2  at most one executed leg has no full-leg witness;
///   C3  rem = a - Σl, and either rem == 0, no Uniswap swap ran and
///       amountOut == Σd; or exactly one Uniswap swap ran, on exactly rem, and
///       amountOut == Σd + U(rem).
///
/// @dev Bounded by the number of whitelisted venues in each `check_*`: a pass
/// means "no counterexample with this many venues", not "for every whitelist".
contract SplitNoRegretHalmos is Test, SymTest {
    PropAMMRouter internal router;
    SymUniswap internal uni;
    MockERC20 internal tin;
    MockERC20 internal tout;
    SymVenue[] internal venues;

    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);
    uint256 internal constant MAX = type(uint128).max;

    function setUp() public {
        uni = new SymUniswap();
        tin = new MockERC20("TokenIn", "TIN");
        tout = new MockERC20("TokenOut", "TOUT");

        AccessManager manager = new AccessManager(address(this));
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(uni), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function check_noRegretCertificate_oneVenue(uint256 amountIn) public {
        _checkCertificate(1, amountIn);
    }

    /// @dev Does NOT close yet: killed by a 2-hour limit with no result
    /// (Yices, Halmos 0.3.3, Apple Silicon). Kept for a stronger solver or a
    /// longer budget; CI runs only the one-venue check.
    function check_noRegretCertificate_twoVenues(uint256 amountIn) public {
        _checkCertificate(2, amountIn);
    }

    function _checkCertificate(uint256 nVenues, uint256 a) internal {
        for (uint256 i = 0; i < nVenues; i++) {
            venues.push(new SymVenue());
            router.addVenue(address(venues[i]));
        }

        tin.mint(USER, a);
        vm.prank(USER);
        tin.approve(address(router), a);
        // `amountOutMin` = 0: the property is about what the split delivers,
        // and a positive minimum only removes runs (it never adds one).
        vm.prank(USER);
        uint256 amountOut = router.swapSplitV1(address(tin), address(tout), a, 0, RECIPIENT, type(uint256).max);

        // Assumption (c).
        for (uint256 j = 0; j < uni.sampleCount(); j++) {
            vm.assume(uni.outs(j) <= MAX);
        }

        assertEq(tout.balanceOf(RECIPIENT), amountOut, "returned amount != received");

        uint256 sumIn;
        uint256 sumOut;
        uint256 legsWithoutFullWitness;
        for (uint256 v = 0; v < nVenues; v++) {
            SymVenue venue = venues[v];
            for (uint256 k = 0; k < venue.swapCount(); k++) {
                uint256 l = venue.swapIns(k);
                uint256 d = venue.swapOuts(k);
                assertGt(l, 0, "C1: executed leg with zero input");
                (bool full, bool partialLeg) = _witness(venue, a, l, d);
                assertTrue(_or(full, partialLeg), "C1: executed leg with no gate witness");
                if (!full) legsWithoutFullWitness++;
                sumIn += l;
                sumOut += d;
            }
        }
        assertLe(legsWithoutFullWitness, 1, "C2: more than one partial leg");

        assertLe(sumIn, a, "C3: venue legs took more than the order");
        uint256 rem = a - sumIn;
        if (rem == 0) {
            assertEq(uni.swapCount(), 0, "C3: Uniswap ran with nothing left");
            assertEq(amountOut, sumOut, "C3: amountOut != venue deliveries");
        } else {
            assertEq(uni.swapCount(), 1, "C3: remainder not coalesced into one Uniswap swap");
            assertEq(uni.swapIns(0), rem, "C3: Uniswap swapped something other than the remainder");
            assertEq(amountOut, sumOut + uni.U(rem), "C3: amountOut != venue deliveries + U(rem)");
        }
    }

    /// @dev Is there a (venue quote, Uniswap sample) pair witnessing C1 for a
    /// leg of input `l` that delivered `d`? Built with branch-free `_and` /
    /// `_or` so Halmos does not fork a path per candidate pair: the whole
    /// existential becomes ONE formula for the solver.
    function _witness(SymVenue venue, uint256 a, uint256 l, uint256 d)
        internal
        view
        returns (bool full, bool partialLeg)
    {
        uint256 nq = venue.quoteCount();
        uint256 ns = uni.sampleCount();
        for (uint256 k = 0; k < nq; k++) {
            uint256 fill = venue.quoteSizes(k);
            uint256 out = venue.quoteOuts(k);
            // Bounds first, so every product below is overflow-free and the
            // facts mean the same over uint256 as over the integers.
            bool sane = _and(_and(fill > 0, fill <= MAX), out <= MAX);
            uint256 fillSafe = sane ? fill : 1;
            uint256 outSafe = sane ? out : 0;
            for (uint256 j = 0; j < ns; j++) {
                uint256 s = uni.sizes(j);
                uint256 q = uni.outs(j);
                bool gate = _and(_and(sane, _and(s > 0, s <= a)), outSafe * s > q * fillSafe);
                full = _or(full, _and(gate, _and(l == fillSafe, d >= outSafe)));
                partialLeg = _or(partialLeg, _and(gate, _and(l < fillSafe, d >= outSafe * l / fillSafe)));
            }
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
