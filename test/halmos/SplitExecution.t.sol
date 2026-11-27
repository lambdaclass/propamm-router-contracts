// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../../src/PropAMMRouter.sol";
import {SplitPlanner} from "../../src/libraries/SplitPlanner.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SymUniswap} from "./mocks/SymUniswap.sol";
import {SymVenue} from "./mocks/SymVenue.sol";
import {PlannerHarness} from "./mocks/PlannerHarness.sol";

/// @title No-regret for many venues: the execution step
/// @notice `SplitNoRegret` proves the no-regret certificate (C1-C3) end to end
/// with ONE venue; with two the whole router does not finish. This check
/// covers the step that the planner checks (`SplitPlanner.t.sol`) leave open:
/// EXECUTING a plan with several venues, each of which may deliver anything
/// or fail.
///
/// Input: any plan of the shape `_waterfall` is proven to emit (W1-W5), with
/// one venue leg per venue, up to `MAX_LEGS`:
///   - venue leg i carries a quote (fill_i -> out_i), 0 < fill_i <= a,
///     0 < out_i <= uint128.max, an input l_i in (0, fill_i] and
///     minOut_i = proRataMin(out_i, fill_i, l_i);
///   - every venue leg but the last is full (l_i == fill_i); the legs sum to
///     at most a; any remainder is one Uniswap leg, and then the last venue
///     leg is full too (W4).
///
/// The venues are `SymVenue`s: each delivers an arbitrary amount, so any
/// subset of the legs can fail its `minOut` and fall back.
///
/// Output: the run satisfies the certificate of `SplitNoRegret`, which
/// `no_regret_lemma.py` turns into amountOut >= U(amountIn):
///   C1  every executed venue leg is its planned leg (same input, l_i > 0) and
///       delivered d_i >= floor(out_i * l_i / fill_i);
///   C2  at most one executed leg is partial;
///   C3  rem = a - sum of executed inputs; either rem == 0, no Uniswap swap and
///       amountOut == sum d; or ONE Uniswap swap on exactly rem and
///       amountOut == sum d + U(rem).
///
/// The gate half of C1 (a Uniswap witness out * s > U(s) * fill) is NOT
/// re-checked here: it is a property of the PLAN (W5 in `SplitPlanner.t.sol`),
/// and C1 above shows an executed leg is exactly its planned leg, so the
/// planned leg's witness carries over. The lemma needs nothing linking that
/// witness to U(rem) beyond assumption (b), so the samples are left out; with
/// them, every "is this size an earlier sample?" lookup forked the run.
///
/// Together with the planner checks (the plan has this shape) and the lemma,
/// this covers no-regret for up to `MAX_LEGS` venues, except for the glue in
/// `_planSplit` that turns venue quotes into candidates, which is only
/// covered end to end with one venue.
contract SplitExecutionHalmos is Test, SymTest {
    PlannerHarness internal router;
    SymUniswap internal uni;
    MockERC20 internal tin;
    MockERC20 internal tout;
    SymVenue[] internal venues;

    address internal constant RECIPIENT = address(0xCAFE);
    uint256 internal constant MAX = type(uint128).max;

    struct Planned {
        uint256 fill;
        uint256 out;
        uint256 l;
    }

    function setUp() public {
        uni = new SymUniswap();
        tin = new MockERC20("TokenIn", "TIN");
        tout = new MockERC20("TokenOut", "TOUT");
        AccessManager manager = new AccessManager(address(this));
        PlannerHarness impl = new PlannerHarness();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(uni), address(manager)));
        router = PlannerHarness(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function check_execute_1(uint256 amountIn) public {
        _checkExecution(1, amountIn);
    }

    function check_execute_2(uint256 amountIn) public {
        _checkExecution(2, amountIn);
    }

    function check_execute_3(uint256 amountIn) public {
        _checkExecution(3, amountIn);
    }

    function check_execute_4(uint256 amountIn) public {
        _checkExecution(4, amountIn);
    }

    /// @dev `MAX_LEGS` venue legs: the most a plan can hold. ~80,000 paths,
    /// ~2 h; a few queries need minutes (the slowest took ~4 min alone).
    /// @custom:halmos --solver-timeout-assertion 600000
    function check_execute_5(uint256 amountIn) public {
        _checkExecution(5, amountIn);
    }

    function _checkExecution(uint256 n, uint256 a) internal {
        vm.assume(a > 0 && a <= MAX);

        Planned[] memory p = new Planned[](n);
        uint256 planned;
        for (uint256 i = 0; i < n; i++) {
            venues.push(new SymVenue());
            router.addVenue(address(venues[i]));
            p[i] = _plannedLeg(a, i + 1 == n);
            planned += p[i].l;
        }
        vm.assume(planned <= a);
        uint256 planRem = a - planned;
        // W4: a remainder means the last venue leg took its whole fill.
        if (planRem > 0) vm.assume(p[n - 1].l == p[n - 1].fill);

        PropAMMRouter.Leg[] memory legs = new PropAMMRouter.Leg[](planRem > 0 ? n + 1 : n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = PropAMMRouter.Leg({
                venue: address(venues[i]),
                amountIn: p[i].l,
                minOut: SplitPlanner.proRataMin(p[i].out, p[i].fill, p[i].l)
            });
        }
        if (planRem > 0) {
            legs[n] = PropAMMRouter.Leg({venue: address(uni), amountIn: planRem, minOut: 0});
        }

        // The router holds the order, as it does after `_pullSplitFunds`.
        tin.mint(address(router), a);
        uint256 amountOut = router.executeLegs(
            legs,
            PropAMMRouter.LegRun({
                tokenIn: address(tin),
                tokenIn_: address(tin),
                tokenOut: address(tout),
                tokenOut_: address(tout),
                totalIn: a,
                // As in `SplitNoRegret`: a positive minimum only removes runs.
                amountOutMin: 0,
                payTo: RECIPIENT,
                swapFor: RECIPIENT,
                deadline: type(uint256).max
            })
        );

        // Assumption (c) of `SplitNoRegret`.
        for (uint256 j = 0; j < uni.sampleCount(); j++) {
            vm.assume(uni.outs(j) <= MAX);
        }

        assertEq(tout.balanceOf(RECIPIENT), amountOut, "returned amount != received");

        uint256 sumIn;
        uint256 sumOut;
        uint256 partialLegs;
        for (uint256 i = 0; i < n; i++) {
            SymVenue venue = venues[i];
            assertLe(venue.swapCount(), 1, "C1: venue swapped more than once");
            if (venue.swapCount() == 0) continue;
            uint256 l = venue.swapIns(0);
            uint256 d = venue.swapOuts(0);
            assertEq(l, p[i].l, "C1: executed input is not the planned leg");
            assertGt(l, 0, "C1: executed leg with zero input");
            assertGe(d, SplitPlanner.proRataMin(p[i].out, p[i].fill, l), "C1: leg delivered below its floor");
            if (l < p[i].fill) partialLegs++;
            sumIn += l;
            sumOut += d;
        }
        assertLe(partialLegs, 1, "C2: more than one partial leg");

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

    /// @dev One venue leg as `_waterfall` emits it (W3). Only the last may be
    /// partial (W4).
    function _plannedLeg(uint256 a, bool last) internal returns (Planned memory x) {
        x.fill = svm.createUint256("fill");
        x.out = svm.createUint256("out");
        vm.assume(x.fill > 0 && x.fill <= a);
        vm.assume(x.out > 0 && x.out <= MAX);
        if (last) {
            x.l = svm.createUint256("l");
            vm.assume(x.l > 0 && x.l <= x.fill);
        } else {
            x.l = x.fill;
        }
    }
}
