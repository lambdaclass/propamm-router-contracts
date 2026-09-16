// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {IPropAMM} from "../src/interfaces/IPropAMM.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter02} from "./mocks/MockSwapRouter02.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockSaturatingPropAMM} from "./mocks/MockSaturatingPropAMM.sol";
import {MockPropAMM} from "./mocks/MockPropAMM.sol";
import {MockFillablePropAMM} from "./mocks/MockFillablePropAMM.sol";
import {MockConcaveUniswap} from "./mocks/MockConcaveUniswap.sol";
import {MockThievingQuoteVenue} from "./mocks/MockThievingQuoteVenue.sol";
import {MockDonatingQuoteVenue} from "./mocks/MockDonatingQuoteVenue.sol";
import {IPropAMMFillable} from "../src/interfaces/IPropAMMFillable.sol";
import {ETH_SENTINEL, WETH} from "../src/libraries/Constants.sol";
import "../src/libraries/Errors.sol";

contract PropAMMRouterSplitTest is Test {
    PropAMMRouter internal router;
    AccessManager internal manager;
    MockSwapRouter02 internal uni;
    MockQuoterV2 internal quoter;
    MockERC20 internal tin;
    MockERC20 internal tout;

    address internal owner = address(this);
    address internal user = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    function setUp() public virtual {
        uni = new MockSwapRouter02();
        quoter = new MockQuoterV2();
        tin = new MockERC20("TokenIn", "TIN");
        tout = new MockERC20("TokenOut", "TOUT");

        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(quoter), address(manager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(payable(address(proxy)));
    }

    function test_isSplitAvailable_trueWhenWhitelistIsSmall() public view {
        assertTrue(router.isSplitAvailable());
    }

    function test_maxLegs_isFive() public view {
        assertEq(router.MAX_LEGS(), 5);
    }

    function test_maxSplitVenues_isTwelve() public view {
        assertEq(router.MAX_SPLIT_VENUES(), 12);
    }

    function test_isSplitAvailable_falsePastTheCap() public {
        for (uint160 i = 1; i <= 13; i++) {
            router.addVenue(address(i));
        }
        assertEq(router.whitelistedVenueCount(), 13);
        assertFalse(router.isSplitAvailable());
    }

    function _fund(uint256 amt) internal {
        tin.mint(user, amt);
        vm.prank(user);
        tin.approve(address(router), amt);
    }

    /// @dev Asserts `logs` contains EXACTLY ONE `Swapped` event, naming
    /// `expectedMarketMaker` and `expectedAmountIn`. Needed because with only
    /// one venue in play, "no candidate at probe time" and "planned then
    /// failed and absorbed into Uniswap" both produce the identical aggregate
    /// output — the output alone cannot distinguish them, only the event trail
    /// can.
    function _assertSingleSwappedEvent(Vm.Log[] memory logs, address expectedMarketMaker, uint256 expectedAmountIn)
        internal
        pure
    {
        uint256 matchCount = 0;
        address marketMaker;
        uint256 amountIn;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IPropAMMRouter.Swapped.selector) {
                matchCount++;
                (amountIn,,, marketMaker) = abi.decode(logs[i].data, (uint256, uint256, address, address));
            }
        }
        require(matchCount == 1, "expected exactly one Swapped event");
        require(marketMaker == expectedMarketMaker, "unexpected marketMaker on Swapped");
        require(amountIn == expectedAmountIn, "unexpected amountIn on Swapped");
    }

    /// @dev With no whitelisted venues there are no candidates, so the whole
    /// order becomes one Uniswap leg. Deliberately NOT an error: it is the same
    /// outcome as a whitelist whose every venue is dead.
    function test_split_emptyWhitelistRoutesEverythingToUniswap() public {
        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 900e18, recipient, block.timestamp + 1);

        assertEq(out, 990e18);
        assertEq(tout.balanceOf(recipient), 990e18);
        assertEq(tin.balanceOf(user), 0, "user's tokenIn should be pulled");
        // MockSwapRouter02 deliberately does not pull tokenIn (see its own
        // docs), so the router retains what it pulled from the user, pulled
        // exactly once.
        assertEq(tin.balanceOf(address(router)), 1000e18, "router should hold exactly what it pulled, once");
    }

    function test_split_revertsPastDeadline() public {
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(Expired.selector);
        router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp - 1);
    }

    function test_split_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        router.swapSplitV1(address(tin), address(tout), 0, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsOnAmountAboveUint128() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AmountTooLarge.selector, tooBig));
        router.swapSplitV1(address(tin), address(tout), tooBig, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsOnIdenticalTokens() public {
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(IdenticalTokens.selector);
        router.swapSplitV1(address(tin), address(tin), 1000e18, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsOnStrayMsgValueForERC20() public {
        _fund(1000e18);
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, 0, 1 ether));
        router.swapSplitV1{value: 1 ether}(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsWhenAggregateBelowMin() public {
        _fund(1000e18);
        uni.setAmountOut(800e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 900e18, 800e18));
        router.swapSplitV1(address(tin), address(tout), 1000e18, 900e18, recipient, block.timestamp + 1);
    }

    function test_split_revertsPastVenueCap() public {
        for (uint160 i = 1; i <= 13; i++) {
            router.addVenue(address(i));
        }
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TooManyVenues.selector, 13));
        router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
    }

    /// @dev Venue caps at exactly half of a 1000 order (500). The full-point
    /// probe (1000) reverts as over-cap; the half-point probe (500) SUCCEEDS
    /// because it lands exactly on the cap — that success is the entire
    /// mechanism under test. `_probeVenue` sees one dead point and one alive
    /// point and takes the alive one directly; Task 6's downward search (for a
    /// venue whose cap sits somewhere below the half point) is NOT exercised
    /// here.
    function test_split_capacityConstrainedVenueTakesHalfAndUniswapTakesRest() public {
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(500e18);
        venue.setRateBps(10_100); // 1% better than Uniswap
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(495e18); // Uniswap fills the 500 remainder at 0.99

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        // 500 @ 1.01 = 505 from the venue, plus 495 from Uniswap.
        assertEq(out, 1000e18);
        assertEq(tout.balanceOf(recipient), 1000e18);
    }

    /// @dev A venue that reverts at both probe points yields no candidate, and
    /// the split degrades to a pure Uniswap route rather than reverting.
    /// Checked two ways, neither of which alone would suffice:
    /// - `vm.expectCall(..., 0)` proves `venue.swap` was never dispatched. This
    ///   is the ONLY observable that survives a reverting sub-call: Solidity
    ///   rolls back all state a reverted call touched, including its own
    ///   emitted events, so a wrongly-planned leg that is dispatched and then
    ///   reverts leaves the identical final event trail as a leg that was
    ///   never planned at all — the event assertion below cannot tell them
    ///   apart on its own.
    /// - The single-`Swapped`-event assertion still pins the Uniswap leg's
    ///   `amountIn` to the full order (M4).
    function test_split_deadVenueIsSkipped() public {
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(0); // reverts at every size
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.expectCall(address(venue), abi.encodeWithSelector(IPropAMM.swap.selector), 0);
        vm.recordLogs();
        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
        _assertSingleSwappedEvent(vm.getRecordedLogs(), address(uni), 1000e18);
    }

    /// @dev A venue quoting zero is not a candidate. Same two-part proof as
    /// `test_split_deadVenueIsSkipped`, and for the same reason.
    function test_split_zeroQuoteVenueIsSkipped() public {
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(0); // quotes 0
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.expectCall(address(venue), abi.encodeWithSelector(IPropAMM.swap.selector), 0);
        vm.recordLogs();
        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
        _assertSingleSwappedEvent(vm.getRecordedLogs(), address(uni), 1000e18);
    }

    /// @dev A planned propAMM leg that under-delivers against its own quoted
    /// `minOut` fails at execution and its input is absorbed into the
    /// coalesced Uniswap leg rather than reverting the whole split. This
    /// drives `_executeLegs`'s `catch` arm (src/PropAMMRouter.sol), which was
    /// unreachable before this task planned any real propAMM leg. It is a
    /// routine production path, not an edge case: `SplitPlanner.proRataMin`
    /// returns the ranking quote EXACTLY (zero tolerance) whenever the leg
    /// equals the full probed fill, so any venue whose delivery ever drifts
    /// below its own quote takes this path.
    ///
    /// Uses `MockCappedPropAMM` at a normal 1000e18 notional, uncapped so
    /// pricing is purely linear (`quote(p) == 2 * quote(p/2)`, never
    /// saturated) and the venue wins the FULL leg through the ordinary,
    /// non-degenerate probe path — unlike `MockPropAMM`, whose quote ignores
    /// the amount argument and can never win a leg at this size (see
    /// `test_split_probeHalfZeroShortcut_failedLegIsAbsorbed`).
    /// `deliveryBps` is independent of `rateBps`, so `swap` can under-deliver
    /// relative to its own `quote` without perturbing the probe.
    ///
    /// `vm.expectCall(..., 1)` proves the venue's `swap` WAS dispatched with
    /// exactly the planned leg (full 1000e18, at the venue's own quoted
    /// minimum) before it failed — the positive counterpart of the
    /// `expectCall(..., 0)` used in the skip tests above. Without it, this
    /// test could not distinguish "correctly planned then failed and
    /// absorbed" from "incorrectly never planned, routed straight to
    /// Uniswap": both produce the identical single
    /// `Swapped(fb, amountIn: 1000e18)` once the reverted sub-call's own
    /// state (including its own would-be `Swapped`) is rolled back.
    function test_split_failedVenueLegIsAbsorbedIntoUniswap() public {
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(10_100); // quotes 1% better than Uniswap, wins the leg
        venue.setDeliveryBps(9_900); // delivers 1% under its own quote at swap time
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        uint256 deadline = block.timestamp + 1;
        uint256 quoted = 1000e18 * 10_100 / 10_000; // 1010e18 — the venue's own minOut
        vm.expectCall(
            address(venue),
            abi.encodeCall(IPropAMM.swap, (address(tin), address(tout), 1000e18, quoted, recipient, deadline)),
            1
        );

        vm.recordLogs();
        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, deadline);

        assertEq(out, 990e18);
        assertEq(tout.balanceOf(recipient), 990e18);
        assertEq(tin.balanceOf(address(venue)), 0, "the reverted leg must not retain the pulled tokenIn");
        _assertSingleSwappedEvent(vm.getRecordedLogs(), address(uni), 1000e18);
    }

    /// @dev Dedicated coverage for `_probeVenue`'s `half == 0` early return,
    /// which is the ONLY way (before Task 6) a flat-quoting venue —
    /// `MockPropAMM.quote()` ignores its amount argument — can become a
    /// candidate at all: at any order where the half point is nonzero, both
    /// probe points return the identical value and the equality guard
    /// discards the venue as ambiguous. This test is NOT the general
    /// absorption proof (see `test_split_failedVenueLegIsAbsorbedIntoUniswap`
    /// for that, at a realistic notional); it exists only to exercise this one
    /// degenerate probe path in its own right, and happens to reuse the same
    /// failure-and-absorption mechanics to do so meaningfully.
    function test_split_probeHalfZeroShortcut_failedLegIsAbsorbed() public {
        MockPropAMM venue = new MockPropAMM();
        venue.setQuote(2); // wins the (uncontested) ranking
        venue.setAmountOut(1); // delivers 1 wei under its own quote
        router.addVenue(address(venue));

        _fund(1);
        uni.setAmountOut(1);

        uint256 deadline = block.timestamp + 1;
        // Same positive `expectCall` proof as the main absorption test above,
        // and for the same reason: without it, this test cannot distinguish
        // "planned then failed and absorbed" from "never planned at all".
        vm.expectCall(
            address(venue), abi.encodeCall(IPropAMM.swap, (address(tin), address(tout), 1, 2, recipient, deadline)), 1
        );

        vm.recordLogs();
        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1, 0, recipient, deadline);

        assertEq(out, 1);
        assertEq(tout.balanceOf(recipient), 1);
        assertEq(tin.balanceOf(address(venue)), 0, "the reverted leg must not retain the pulled tokenIn");
        _assertSingleSwappedEvent(vm.getRecordedLogs(), address(uni), 1);
    }

    /// @dev Cap 200 inside a 1000 order. Probes at 1000 and 500 both return the
    /// flat 200-ceiling, so neither is a fillable size. Halving from 500 gives
    /// 250 (still saturated) then 125 (strictly below the ceiling) — which is
    /// the size the venue actually fills.
    function test_split_downwardProbeRecoversSaturatedVenue() public {
        MockSaturatingPropAMM venue = new MockSaturatingPropAMM();
        venue.setCap(200e18);
        venue.setRateBps(10_100);
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(875e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        // 125 @ 1.01 = 126.25 from the venue, 875 from Uniswap.
        assertEq(out, 1001.25e18);
    }

    /// @dev Cap so far below the order that the halving budget is exhausted
    /// before finding a fillable size. The venue is DECLINED rather than handed
    /// input it will not fill, and the order routes wholly through Uniswap.
    function test_split_saturatedVenueDeclinedWhenBudgetExhausted() public {
        MockSaturatingPropAMM venue = new MockSaturatingPropAMM();
        venue.setCap(1); // 1 wei of capacity against a 1000e18 order
        venue.setRateBps(10_100);
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
    }

    /// @dev Drift inside the τ band is NOT saturation: the venue keeps its full
    /// probe point rather than being halved.
    function test_split_driftInsideToleranceKeepsFullPoint() public {
        MockSaturatingPropAMM venue = new MockSaturatingPropAMM();
        venue.setCap(type(uint256).max); // perfectly linear, never saturates
        venue.setRateBps(10_100);
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(0);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 1010e18); // whole order at 1.01
    }

    /// @dev A venue advertising the extension is priced in ONE call and can
    /// declare a capacity far below the order size — something the blind probe
    /// could not locate.
    function test_split_extensionGivesExactCapacityInOneCall() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        venue.setFillable(300e18);
        venue.setOut(303e18); // 1.01 rate on the 300 it will take
        venue.setAmountOut(303e18);
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(693e18); // 700 remainder at 0.99

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 996e18);
    }

    /// @dev A venue reporting MORE than it was offered has broken the interface.
    /// The candidate is discarded, not clamped: clamping the fill while keeping
    /// an `amountOut` quoted for the larger size would inflate its rate by
    /// exactly the over-report and let it sweep the ranking.
    function test_split_extensionOverReportIsDiscarded() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        venue.setFillable(5000e18); // more than the 1000 offered
        venue.setOut(5050e18);
        venue.setAmountOut(5050e18);
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18); // venue ignored entirely
    }

    /// @dev A non-whitelisted address advertising the extension with an
    /// unbeatable rate never becomes a candidate and never receives a leg.
    /// This is enforced by `_collectVenues`, which builds `venueSet` by reading
    /// the whitelist `EnumerableSet` directly — a non-member can never appear
    /// in it, so it never reaches `_probeVenue` at all. (The `_isVenue` check
    /// inside `_probeVenue` is separate defense-in-depth for a direct-call path
    /// that does not exist in this design; see its own comment. This test
    /// cannot observe that check's position, only the end-to-end outcome.)
    /// `vm.expectCall(..., 0)` proves the router never touched the address at
    /// all — asserting only the aggregate output would also pass if the rogue
    /// venue were called and merely lost the ranking.
    function test_split_nonWhitelistedFillableNeverBecomesCandidate() public {
        MockFillablePropAMM rogue = new MockFillablePropAMM();
        rogue.setFillable(1000e18);
        rogue.setOut(2000e18); // an unbeatable rate, if it were trusted
        // deliberately NOT whitelisted

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.expectCall(address(rogue), abi.encodeWithSelector(IPropAMMFillable.quoteFillable.selector), 0);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
    }

    /// @dev Six venues each declaring 200 of fillable capacity against a 1200
    /// order. MAX_LEGS is 5, so only five get legs (1000 total) and the last
    /// 200 falls to Uniswap. The extension is what makes this expressible: a
    /// blind probe cannot locate a 200 cap inside a 1200 order.
    function test_split_maxLegsBinds() public {
        for (uint256 i = 0; i < 6; i++) {
            MockFillablePropAMM v = new MockFillablePropAMM();
            v.setFillable(200e18);
            v.setOut(202e18); // 1.01
            v.setAmountOut(202e18);
            router.addVenue(address(v));
        }
        _fund(1200e18);
        uni.setAmountOut(198e18); // the 200 remainder at 0.99

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1200e18, 0, recipient, block.timestamp + 1);

        // 5 legs * 202 = 1010, plus 198 from Uniswap.
        assertEq(out, 1208e18);
    }

    /// @dev A venue's extension declares ZERO fillable capacity. The candidate
    /// is discarded by `_gatherCandidates`'s `fill == 0` filter, and the whole
    /// order routes to Uniswap. The venue's blind-probe `quote` is set to a
    /// rate the two-point probe would find live and attractive (1% better than
    /// Uniswap) — if the extension branch were ever bypassed, this venue would
    /// win a leg instead of being declined, so the assertion below proves the
    /// decline comes from the extension saying "zero", not from the venue
    /// being unreachable through the blind probe too.
    function test_split_extensionZeroFillDeclinesDespiteAttractiveBlindProbeRate() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        venue.setFillable(0);
        venue.setOut(0);
        venue.setQuoteRateBps(10_100); // what the blind probe would see if consulted
        venue.setAmountOut(1010e18); // what it would deliver if that leg ran
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
    }

    /// @dev A venue whose extension REVERTS is declined via the branch's
    /// `catch` clause rather than reverting the whole split — realistic for a
    /// venue that reverts when it has no inventory left.
    function test_split_extensionRevertYieldsNoCandidate() public {
        MockFillablePropAMM venue = new MockFillablePropAMM();
        venue.setRevertOnQuoteFillable(true);
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
    }

    /// @dev Builds a router wired against a `MockConcaveUniswap` as BOTH the
    /// fallback swap router and the fallback quoter, so `_waterfall`'s
    /// reference cutoff is actually live (see the class doc for why the
    /// shared harness's `MockQuoterV2` leaves it dormant for every other test
    /// in this file).
    function _concaveRouter() internal returns (PropAMMRouter r, MockConcaveUniswap c) {
        c = new MockConcaveUniswap();
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (address(c), address(c), address(manager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        r = PropAMMRouter(payable(address(proxy)));
    }

    /// @dev A venue priced BELOW the Uniswap reference is cut off and gets no
    /// leg, even though it quoted successfully.
    function test_split_belowMarketVenueIsCutOff() public {
        (PropAMMRouter r, MockConcaveUniswap c) = _concaveRouter();
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(5_000); // 0.5 — far below Uniswap's ~1.0
        r.addVenue(address(venue));

        tin.mint(user, 1000e18);
        vm.prank(user);
        tin.approve(address(r), 1000e18);

        vm.prank(user);
        uint256 out = r.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        // Whole order through Uniswap: 1_000_000 * 1000 / 1_001_000
        assertEq(out, c.reserveOut() * 1000e18 / (c.reserveIn() + 1000e18));
    }

    /// @dev A venue that beats Uniswap keeps its leg.
    function test_split_aboveMarketVenueKeepsItsLeg() public {
        (PropAMMRouter r,) = _concaveRouter();
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(20_000); // 2.0 — unambiguously better
        r.addVenue(address(venue));

        tin.mint(user, 1000e18);
        vm.prank(user);
        tin.approve(address(r), 1000e18);

        vm.prank(user);
        uint256 out = r.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 2000e18);
    }

    /// @dev Neither `test_split_belowMarketVenueIsCutOff` nor
    /// `test_split_aboveMarketVenueKeepsItsLeg` actually reaches the
    /// refinement branch: both venues resolve identically against the
    /// under-sized floor reference (`amountIn/100`) and the refined
    /// (`amountIn`) one, so a build that skipped refinement entirely (only
    /// ever comparing against the floor reference) would still pass them.
    /// This test picks a rate strictly between Uniswap's unit rate at the
    /// floor size (10e18, ~0.99999) and at the true residual (1000e18,
    /// ~0.999001) — contested against the former, NOT contested against the
    /// latter — so it can only pass if the one-shot refinement actually reruns
    /// the quote at the true remaining amount and re-admits the candidate.
    function test_split_refinementAdmitsCandidateBetweenReferenceSizes() public {
        (PropAMMRouter r,) = _concaveRouter();
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(9_995); // between ~0.999001 (full ref) and ~0.99999 (floor ref)
        r.addVenue(address(venue));

        tin.mint(user, 1000e18);
        vm.prank(user);
        tin.approve(address(r), 1000e18);

        vm.prank(user);
        uint256 out = r.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        // Whole order through the venue at 0.9995, not through Uniswap.
        assertEq(out, 1000e18 * 9_995 / 10_000);
    }

    /// @dev If the refined re-quote reverts (e.g. QuoterV2 running past
    /// available liquidity at the larger, refined size) or returns an
    /// out-of-range value, the ORIGINAL reference — which had already
    /// rejected this candidate — must be kept rather than discarded. Adopting
    /// a zeroed-out refined reference would make the recheck vacuously false
    /// and wrongly admit the candidate (and every later one, since a zero
    /// `refOut` never contests anything for the rest of the loop). Here the
    /// venue is priced below the floor reference (so it is contested and
    /// triggers the one-shot refinement), and the refined re-quote at the
    /// true remainder (1000e18) is made to revert by capping
    /// `MockConcaveUniswap`'s quotable size at 500e18 — comfortably above the
    /// 10e18 floor reference, comfortably below the refined size. A correct
    /// implementation must still reject the venue and route through Uniswap.
    function test_split_refinementRequoteFailureKeepsWorkingReference() public {
        (PropAMMRouter r, MockConcaveUniswap c) = _concaveRouter();
        c.setQuoteRevertAboveSize(500e18);

        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(9_990); // below the floor reference's ~0.99999 rate — contested
        r.addVenue(address(venue));

        tin.mint(user, 1000e18);
        vm.prank(user);
        tin.approve(address(r), 1000e18);

        vm.prank(user);
        uint256 out = r.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        // Whole order through Uniswap: a failed refinement must not admit the
        // venue it was trying (and failing) to re-check.
        assertEq(out, c.reserveOut() * 1000e18 / (c.reserveIn() + 1000e18));
    }

    /// @dev The reference quote must be taken with `(tokenIn, tokenOut)` in
    /// the order the caller actually sold/bought, not transposed.
    /// `MockConcaveUniswap`'s pricing ignores both addresses, so a
    /// transposition at the `_tryQuote` call sites in `_waterfall` — the exact
    /// parameters this task added — would otherwise pass every value-based
    /// assertion in this file unnoticed. The mock instead records the pair it
    /// was last quoted with, so this test checks the order directly.
    function test_split_referenceQuoteUsesCorrectTokenOrder() public {
        (PropAMMRouter r, MockConcaveUniswap c) = _concaveRouter();
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(20_000);
        r.addVenue(address(venue));

        tin.mint(user, 1000e18);
        vm.prank(user);
        tin.approve(address(r), 1000e18);

        vm.prank(user);
        r.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        assertEq(c.lastQuoteTokenIn(), address(tin), "reference quote used the wrong tokenIn");
        assertEq(c.lastQuoteTokenOut(), address(tout), "reference quote used the wrong tokenOut");
    }

    /// @dev Sibling of `test_split_referenceQuoteUsesCorrectTokenOrder`, aimed
    /// at the OTHER `_tryQuote` call site: the refined re-quote. A venue rate
    /// of 9995bps is (as in `test_split_refinementAdmitsCandidateBetweenReferenceSizes`)
    /// contested against the floor reference, so refinement fires and the
    /// refined call overwrites `lastQuoteTokenIn`/`lastQuoteTokenOut` — the
    /// values asserted here reflect ONLY that second call, so this cannot pass
    /// by accident if only the first call site were correct.
    function test_split_refinedReferenceQuoteUsesCorrectTokenOrder() public {
        (PropAMMRouter r, MockConcaveUniswap c) = _concaveRouter();
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(9_995); // contested at the floor reference, triggers refinement
        r.addVenue(address(venue));

        tin.mint(user, 1000e18);
        vm.prank(user);
        tin.approve(address(r), 1000e18);

        vm.prank(user);
        r.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);

        assertEq(c.lastQuoteTokenIn(), address(tin), "refined reference quote used the wrong tokenIn");
        assertEq(c.lastQuoteTokenOut(), address(tout), "refined reference quote used the wrong tokenOut");
    }

    /// @dev A venue that consumes in-flight user funds while quoting reverts
    /// the whole split. This is what pays for pulling before quoting.
    ///
    /// `stealAmount` is 1e18, but the theft happens twice (2e18 total): a
    /// non-`IPropAMMFillable` venue is probed at both `amountIn` and
    /// `amountIn / 2` (see `_probeVenue`), and `MockThievingQuoteVenue.quote`
    /// steals `stealAmount` on every call, not just the first. The invariant
    /// only needs a net fall below the snapshot to fire, so this test does not
    /// depend on that count — it is noted here only so a future change to the
    /// probe's call count doesn't turn into a mystery if this test's trace is
    /// ever inspected.
    function test_split_r1_thievingQuoteReverts() public {
        MockThievingQuoteVenue thief = new MockThievingQuoteVenue();
        thief.configure(address(router), address(tin), 1e18);
        router.addVenue(address(thief));

        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(QuoteBalanceInvariantViolated.selector);
        router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
    }

    /// @dev A donation during the quote phase is TOLERATED. Rejecting it would
    /// hand any whitelisted venue a one-wei denial of service over every
    /// caller's split, including splits it is not part of.
    function test_split_r1_donationIsTolerated() public {
        MockDonatingQuoteVenue donor = new MockDonatingQuoteVenue();
        donor.configure(address(router), address(tin), 1);
        router.addVenue(address(donor));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);

        // The donated wei is inert — legs are sized from amountIn, never from
        // the balance — so it is stranded on the router for `rescueTokens`.
        // `MockDonatingQuoteVenue.quote` donates 1 wei on EVERY call, and
        // `_probeVenue` makes two `_tryQuote` calls for a non-`IPropAMMFillable`
        // venue that never returns a usable quote (once at `amountIn`, once at
        // `amountIn / 2` — a venue quoting 0 at both points is neither
        // saturated nor a live single point, so nothing short-circuits the
        // second call). That is one wei per call, so `+ 2`, not `+ 1`: if a
        // future change to the probe alters its call count, this assertion
        // should fail loudly with an obvious cause rather than a silent
        // mystery off-by-one.
        // NOTE: `MockSwapRouter02` deliberately does NOT pull `tokenIn` (see its
        // NatSpec), so the router also still holds the 1000e18 it pulled — the
        // donation is the `+ 2` on top. Do not loosen this to `> 1000e18`: the
        // exact figure is what pins the donation as inert rather than swapped.
        assertEq(tin.balanceOf(address(router)), 1000e18 + 2);
    }
}

/// @title PropAMMRouterSplitEthTest
/// @notice Exercises `swapSplitV1`'s two ETH-sentinel branches: `_pullSplitFunds`'s
/// wrap-and-require-msg.value arm, and `_executeLegs`'s recipient override plus
/// unwrap-to-`payTo` arm. Both are reachable today through the empty-whitelist
/// stub's fallback-only plan, but `PropAMMRouterSplitTest`'s ERC20-only harness
/// never drives them.
/// @dev Own router instance rather than bending the shared harness:
/// `PropAMMRouterSplitTest`'s `MockSwapRouter02` deliberately does not pull
/// `tokenIn` (see its own docs), which cannot fund a WETH-backed unwrap.
/// Modeled on `test/PropAMMRouterEth.t.sol`, which solves the same
/// ETH-wrapping problem for the non-split entrypoints: a `MockWETH` etched at
/// the hard-coded WETH address, and a pull-based `MockV3SwapRouter` fallback.
contract PropAMMRouterSplitEthTest is Test {
    PropAMMRouter internal router;
    AccessManager internal manager;
    MockV3SwapRouter internal fallbackRouter;
    MockQuoterV2 internal quoter;
    MockERC20 internal tin;
    MockERC20 internal tout;

    address internal owner = address(this);
    address internal user = address(0xBEEF);
    address internal recipient;

    function setUp() public {
        fallbackRouter = new MockV3SwapRouter();
        quoter = new MockQuoterV2();
        tin = new MockERC20("TokenIn", "TIN");
        tout = new MockERC20("TokenOut", "TOUT");
        recipient = makeAddr("splitEthRecipient");

        // Put a working WETH at the address the router hard-codes.
        vm.etch(WETH, address(new MockWETH()).code);

        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(fallbackRouter), address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    /// @dev Covers `_executeLegs`'s ETH-out branch: `recipient_` is overridden
    /// to `address(this)` (the router) so it can hold the gross WETH before
    /// `_sendWrappedETH` unwraps it and forwards real ETH to `payTo`. With no
    /// whitelisted venues the stub's single leg IS the fallback, so this
    /// drives the branch through the same plan the ERC20-only suite already
    /// exercises for an ERC20 `tokenOut`.
    function test_split_ethOut_unwrapsToRecipient() public {
        uint256 amountIn = 1000e18;
        uint256 amountOut = 1 ether;

        tin.mint(user, amountIn);
        vm.prank(user);
        tin.approve(address(router), amountIn);

        // Fund the fallback with WETH backed by real ETH, so the later
        // `IWETH.withdraw` inside `_sendWrappedETH` has ETH to pay out.
        vm.deal(address(fallbackRouter), amountOut);
        vm.prank(address(fallbackRouter));
        MockWETH(payable(WETH)).deposit{value: amountOut}();
        fallbackRouter.setAmountOut(amountOut);

        vm.prank(user);
        uint256 out =
            router.swapSplitV1(address(tin), ETH_SENTINEL, amountIn, amountOut, recipient, block.timestamp + 1);

        assertEq(out, amountOut);
        assertEq(recipient.balance, amountOut);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH stranded in router");
    }

    /// @dev Covers `_pullSplitFunds`'s ETH-in branch: `msg.value == amountIn`
    /// is enforced and the ETH is wrapped to WETH before the (fallback-only)
    /// plan runs.
    function test_split_ethIn_wrapsAndDelivers() public {
        uint256 amountIn = 1 ether;
        uint256 amountOut = 500e18;

        tout.mint(address(fallbackRouter), amountOut);
        fallbackRouter.setAmountOut(amountOut);
        vm.deal(user, amountIn);

        vm.prank(user);
        uint256 out = router.swapSplitV1{value: amountIn}(
            ETH_SENTINEL, address(tout), amountIn, amountOut, recipient, block.timestamp + 1
        );

        assertEq(out, amountOut);
        assertEq(tout.balanceOf(recipient), amountOut);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH stranded in router");
        assertEq(address(router).balance, 0, "no ETH stranded in router");
    }
}
