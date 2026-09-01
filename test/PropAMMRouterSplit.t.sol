// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOperatorERC20} from "./mocks/MockOperatorERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockPartialFillPropAMM} from "./mocks/MockPartialFillPropAMM.sol";
import {MockThievingQuoteVenue} from "./mocks/MockThievingQuoteVenue.sol";
import {MockLinearSwapRouter, MockLinearQuoterV2} from "./mocks/MockLinearUniswap.sol";
import "../src/libraries/Errors.sol";

contract PropAMMRouterSplitTest is Test {
    PropAMMRouter router;
    AccessManager manager;
    MockLinearSwapRouter uni;
    MockLinearQuoterV2 quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        uni = new MockLinearSwapRouter();
        quoter = new MockLinearQuoterV2();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), data))));
        // Uniswap pays 1:1 by default; venues are configured per test.
        uni.setPrice(1, 1);
        quoter.setPrice(1, 1);
    }

    function _newVenue(uint256 num, uint256 den, uint256 cap, MockCappedPropAMM.CapMode mode)
        internal
        returns (MockCappedPropAMM v)
    {
        v = new MockCappedPropAMM(num, den);
        v.setCap(cap);
        v.setCapMode(mode);
        tokenOut.mint(address(v), 100_000_000e18);
        vm.prank(owner);
        router.addVenue(address(v));
    }

    function _fundUser(uint256 amount) internal {
        tokenIn.mint(user, amount);
        vm.prank(user);
        tokenIn.approve(address(router), amount);
    }

    function _split(
        address[] memory venues,
        uint256[] memory hints,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 maxLegs
    ) internal returns (uint256) {
        vm.prank(user);
        return router.swapSplitV1(
            venues,
            hints,
            address(tokenIn),
            address(tokenOut),
            amountIn,
            amountOutMin,
            maxLegs,
            user,
            block.timestamp + 1
        );
    }

    function _noHints() internal pure returns (uint256[] memory h) {
        return h;
    }

    /// @dev The router is a pass-through: it must never retain input funds.
    function _assertRouterEmpty() internal view {
        assertEq(tokenIn.balanceOf(address(router)), 0, "router retained tokenIn");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router retained tokenOut");
    }

    function test_split_capacityConstrained_waterfallsAcrossTwoVenues() public {
        // A pays x1.2 with a 150 cap (inside the probe window: the full probe
        // at 250 reverts, the half probe at 125 succeeds, so A is discovered
        // as a 125-fill candidate); B pays x1.1 uncapped. Order = 250.
        MockCappedPropAMM a = _newVenue(10, 12, 150e18, MockCappedPropAMM.CapMode.HardRevert);
        MockCappedPropAMM b = _newVenue(10, 11, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(250e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);

        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);

        // A quoted at 250 (revert) and 125 (ok, x1.2 -> 150): fill 125.
        // B quoted at 250 ok (x1.1 -> 275): fill 250.
        // Ranking: A (1.2) > B (1.1) > uni (1.0). Legs: A 125, B 125.
        // Delivered: 125*1.2 + 125*1.1 = 150 + 137.5 = 287.5.
        assertEq(amountOut, 287.5e18);
        assertEq(tokenIn.balanceOf(address(a)), 125e18);
        assertEq(tokenIn.balanceOf(address(b)), 125e18);
        assertEq(tokenOut.balanceOf(user), 287.5e18);
        assertEq(tokenIn.balanceOf(user), 0);
        _assertRouterEmpty();
    }

    function test_split_partialFillExtensionGivesExactCapacity() public {
        // Same economics but A implements IPropAMMPartialFill: exact 150 cap
        // is used instead of the probe's 125 estimate.
        MockPartialFillPropAMM a = new MockPartialFillPropAMM(10, 12);
        a.setCap(150e18);
        tokenOut.mint(address(a), 1_000_000e18);
        vm.prank(owner);
        router.addVenue(address(a));
        MockCappedPropAMM b = _newVenue(10, 11, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(250e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);

        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);
        // Legs: A 150 (exact cap, x1.2 -> 180), B 100 (x1.1 -> 110).
        assertEq(amountOut, 290e18);
        assertEq(tokenIn.balanceOf(address(a)), 150e18);
        assertEq(tokenIn.balanceOf(address(b)), 100e18);
        assertEq(tokenOut.balanceOf(user), 290e18);
        _assertRouterEmpty();
    }

    function test_split_saturatedVenueLosingToUniswapIsCutOff() public {
        // A saturates so far below the order size that even its half point is
        // above the cap, so BOTH probe points return the same saturated
        // output and the surviving candidate's rate (0.96) is worse than
        // Uniswap's 1.0. This pins the reference-rate CUTOFF: a candidate that
        // loses to Uniswap gets no leg at all. (It does not pin saturation
        // detection itself — see
        // test_split_saturationDetectionKeepsHalfPointLeg for that.)
        MockCappedPropAMM a = _newVenue(10, 12, 100e18, MockCappedPropAMM.CapMode.Saturate);
        _fundUser(250e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);
        // quote(250) = cap*1.2 = 120; quote(125) = 120 too (125 > cap ->
        // saturate). Both points saturated: out(250)=120 == out(125)=120 ->
        // isSaturated(120, 120) = true -> fill = 125 at out 120 (rate 0.96
        // < uni 1.0) -> A LOSES to uniswap. Everything routes via uniswap.
        assertEq(amountOut, 250e18);
        assertEq(tokenIn.balanceOf(address(a)), 0);
        assertEq(tokenOut.balanceOf(user), 250e18);
        _assertRouterEmpty();
    }

    function test_split_saturationDetectionKeepsHalfPointLeg() public {
        // A pays x2 with a 100 cap, saturating above it. Order = 150.
        // quote(150) saturates to 200 (rate 1.33); quote(75) is under the cap
        // and returns 150 (rate 2.0). isSaturated(200, 150) is true, so the
        // candidate is the HALF point: fill 75 -> out 150.
        //
        // Decisive by construction: without saturation detection the
        // candidate would be fill 150 / out 200, the leg would be sized 150,
        // the venue's own cap check would revert it, and the entire 150 would
        // coalesce into Uniswap for a total of 150e18 with the venue paid
        // nothing. Both assertions below separate the two outcomes.
        MockCappedPropAMM a = _newVenue(10, 20, 100e18, MockCappedPropAMM.CapMode.Saturate);
        _fundUser(150e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 amountOut = _split(venues, _noHints(), 150e18, 0, 8);
        // A leg: 75 -> 150. Remainder 75 -> uniswap 1:1 -> 75. Total 225.
        assertEq(amountOut, 225e18);
        assertEq(tokenIn.balanceOf(address(a)), 75e18);
        assertEq(tokenOut.balanceOf(user), 225e18);
        _assertRouterEmpty();
    }

    function test_split_probeHintDiscoversSmallCap() public {
        // Same saturating venue, but the caller hints its true cap: the
        // probe quotes at 100 (ok, x1.2 -> 120) and 50; A wins a 100 leg.
        MockCappedPropAMM a = _newVenue(10, 12, 100e18, MockCappedPropAMM.CapMode.Saturate);
        _fundUser(250e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);
        uint256[] memory hints = new uint256[](1);
        hints[0] = 100e18;

        uint256 amountOut = _split(venues, hints, 250e18, 0, 8);
        // A leg: 100 -> 120. Remainder 150 -> uniswap 1:1 -> 150. Total 270.
        assertEq(amountOut, 270e18);
        assertEq(tokenIn.balanceOf(address(a)), 100e18);
        assertEq(tokenOut.balanceOf(user), 270e18);
        _assertRouterEmpty();
    }

    /// @dev Smoke test, not a regression guard for the `out == 0` skip: a
    /// zero-quote candidate is inert either way, because the reference cutoff
    /// reads `0 <= 0` as contested and breaks out of the waterfall, giving the
    /// same all-Uniswap result whether or not `_gatherCandidates` filtered it.
    /// The filter is defensive; its absence is not observable from outside.
    function test_split_zeroQuoteVenueDoesNotDisruptRouting() public {
        MockCappedPropAMM a = _newVenue(10, 12, 100e18, MockCappedPropAMM.CapMode.ZeroQuote);
        _fundUser(250e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);
        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);
        // Both probe points above cap -> zero quotes -> skipped -> all uniswap.
        assertEq(amountOut, 250e18);
        assertEq(tokenIn.balanceOf(address(a)), 0);
        _assertRouterEmpty();
    }

    function test_split_r1_thievingQuoteReverts() public {
        // tokenIn is operator-enabled; a whitelisted venue steals 1 wei
        // during its quote. The split must revert the R1 invariant.
        MockOperatorERC20 opIn = new MockOperatorERC20("OpIn", "OPIN");
        MockThievingQuoteVenue thief = new MockThievingQuoteVenue();
        opIn.setOperator(address(thief));
        vm.prank(owner);
        router.addVenue(address(thief));

        opIn.mint(user, 100e18);
        vm.prank(user);
        opIn.approve(address(router), 100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(thief);

        vm.prank(user);
        vm.expectRevert(QuoteBalanceInvariantViolated.selector);
        router.swapSplitV1(
            venues, _noHints(), address(opIn), address(tokenOut), 100e18, 0, 8, user, block.timestamp + 1
        );

        // The whole call rolled back: the user still holds every wei.
        assertEq(opIn.balanceOf(user), 100e18);
        assertEq(opIn.balanceOf(address(router)), 0);
        assertEq(opIn.balanceOf(address(thief)), 0);
    }

    function test_split_venueWorseThanUniswapIsCutOff() public {
        // A pays x0.9 (worse than uni 1:1): must get NO leg.
        MockCappedPropAMM a = _newVenue(10, 9, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);
        uint256 amountOut = _split(venues, _noHints(), 100e18, 0, 8);
        assertEq(amountOut, 100e18); // all via uniswap 1:1
        assertEq(tokenIn.balanceOf(address(a)), 0);
        _assertRouterEmpty();
    }

    function test_split_maxLegsTruncatesToBestVenues() public {
        // Three venues, rates 1.3 > 1.2 > 1.1, each capped at 50; order 200,
        // maxLegs = 2: only the two best get legs; the rest -> uniswap.
        MockCappedPropAMM a = _newVenue(10, 13, 50e18, MockCappedPropAMM.CapMode.HardRevert);
        MockCappedPropAMM b = _newVenue(10, 12, 50e18, MockCappedPropAMM.CapMode.HardRevert);
        MockCappedPropAMM c = _newVenue(10, 11, 50e18, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(200e18);

        address[] memory venues = new address[](3);
        venues[0] = address(c); // deliberately unsorted input
        venues[1] = address(a);
        venues[2] = address(b);
        uint256[] memory hints = new uint256[](3);
        hints[0] = 50e18;
        hints[1] = 50e18;
        hints[2] = 50e18;

        uint256 amountOut = _split(venues, hints, 200e18, 0, 2);
        // a: 50 -> 65, b: 50 -> 60, uniswap: 100 -> 100. c gets nothing.
        assertEq(amountOut, 225e18);
        assertEq(tokenIn.balanceOf(address(a)), 50e18);
        assertEq(tokenIn.balanceOf(address(b)), 50e18);
        assertEq(tokenIn.balanceOf(address(c)), 0);
        _assertRouterEmpty();
    }

    function test_split_uniswapLegNotCountedAgainstMaxLegs() public {
        // maxLegs = 1 with a capped venue: 1 prop leg + the uniswap
        // remainder leg must BOTH run.
        MockCappedPropAMM a = _newVenue(10, 12, 50e18, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(200e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);
        uint256[] memory hints = new uint256[](1);
        hints[0] = 50e18;

        uint256 amountOut = _split(venues, hints, 200e18, 0, 1);
        // a: 50 -> 60; uniswap: 150 -> 150.
        assertEq(amountOut, 210e18);
        assertEq(tokenIn.balanceOf(address(a)), 50e18);
        _assertRouterEmpty();
    }

    function test_split_propsCoverEverything_noUniswapLeg() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);
        uint256 amountOut = _split(venues, _noHints(), 100e18, 0, 8);
        assertEq(amountOut, 120e18);
        assertEq(tokenIn.balanceOf(address(uni)), 0); // uniswap never touched
        _assertRouterEmpty();
    }

    function test_split_aggregateMinStillGoverns() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 121e18, 120e18));
        router.swapSplitV1(
            venues, _noHints(), address(tokenIn), address(tokenOut), 100e18, 121e18, 8, user, block.timestamp + 1
        );
        // The whole call rolled back: the user still holds every wei, and the
        // reverted quote/probe phase left no dust in the router.
        assertEq(tokenIn.balanceOf(user), 100e18);
        _assertRouterEmpty();
    }

    function test_split_emptyVenuesUsesWhitelist() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory none = new address[](0);
        uint256 amountOut = _split(none, _noHints(), 100e18, 0, 8);
        assertEq(amountOut, 120e18);
        assertEq(tokenIn.balanceOf(address(a)), 100e18);
        _assertRouterEmpty();
    }

    function test_split_whitelistLargerThanMaxReverts() public {
        for (uint256 i = 0; i < 9; i++) {
            _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        }
        _fundUser(1e18);
        address[] memory none = new address[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TooManyVenues.selector, 9));
        router.swapSplitV1(none, _noHints(), address(tokenIn), address(tokenOut), 1e18, 0, 8, user, block.timestamp + 1);
        // Reverted before any fund pull: the user's balance is untouched.
        assertEq(tokenIn.balanceOf(user), 1e18);
        _assertRouterEmpty();
    }

    function test_split_hintsWithEmptyVenuesReverts() public {
        _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(1e18);
        address[] memory none = new address[](0);
        uint256[] memory hints = new uint256[](1);
        hints[0] = 1;
        vm.prank(user);
        vm.expectRevert(ArrayLengthMismatch.selector);
        router.swapSplitV1(none, hints, address(tokenIn), address(tokenOut), 1e18, 0, 8, user, block.timestamp + 1);
        assertEq(tokenIn.balanceOf(user), 1e18);
        _assertRouterEmpty();
    }

    function test_split_hintsLengthMismatchReverts() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(1e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);
        uint256[] memory hints = new uint256[](2);
        vm.prank(user);
        vm.expectRevert(ArrayLengthMismatch.selector);
        router.swapSplitV1(venues, hints, address(tokenIn), address(tokenOut), 1e18, 0, 8, user, block.timestamp + 1);
        assertEq(tokenIn.balanceOf(user), 1e18);
        _assertRouterEmpty();
    }

    function test_split_amountAboveUint128Reverts() public {
        _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        uint256 huge = uint256(type(uint128).max) + 1;
        address[] memory none = new address[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AmountTooLarge.selector, huge));
        router.swapSplitV1(none, _noHints(), address(tokenIn), address(tokenOut), huge, 0, 8, user, block.timestamp + 1);
    }

    function test_split_zeroMaxLegsReverts() public {
        _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        address[] memory none = new address[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidLegCount.selector, 0));
        router.swapSplitV1(none, _noHints(), address(tokenIn), address(tokenOut), 1e18, 0, 0, user, block.timestamp + 1);
    }

    function test_split_duplicateVenuesDeduped() public {
        // Capped below amountIn so a duplicate, undeduped probe is
        // observable: each duplicate entry independently probes and would
        // contribute its own leg (2x50 -> 120 total, venue balance 100e18)
        // if dedup were removed, versus the single-leg outcome asserted
        // below (50 -> 60 from the venue, 50 -> 50 from uniswap, 110e18
        // total, venue balance 50e18). With the brief's original uncapped
        // venue, a single probe already fills the whole order, so the
        // deduped and undeduped outcomes were numerically identical and the
        // test could not have caught a missing dedup; capping the venue
        // makes the assertions decisive.
        MockCappedPropAMM a = _newVenue(10, 12, 60e18, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(a);
        uint256 amountOut = _split(venues, _noHints(), 100e18, 0, 8);
        assertEq(amountOut, 110e18); // one leg (50 -> 60) + uniswap (50 -> 50), not two prop legs
        assertEq(tokenIn.balanceOf(address(a)), 50e18);
        _assertRouterEmpty();
    }
}
