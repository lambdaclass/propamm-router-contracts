// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {ETH_SENTINEL, WETH} from "../src/libraries/Constants.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOperatorERC20} from "./mocks/MockOperatorERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockPartialFillPropAMM} from "./mocks/MockPartialFillPropAMM.sol";
import {MockThievingQuoteVenue} from "./mocks/MockThievingQuoteVenue.sol";
import {MockDonatingQuoteVenue} from "./mocks/MockDonatingQuoteVenue.sol";
import {IPropAMM} from "../src/interfaces/IPropAMM.sol";
import {MockThievingQuoterV2} from "./mocks/MockThievingQuoterV2.sol";
import {MockLinearSwapRouter, MockLinearQuoterV2} from "./mocks/MockLinearUniswap.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {FrontendFees} from "../src/libraries/FrontendFees.sol";
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
    address feeRecipient = makeAddr("feeRecipient");

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
        return _splitFb(venues, hints, amountIn, amountOutMin, 0, maxLegs);
    }

    /// @dev `_split` plus an explicit floor on the coalesced Uniswap leg.
    function _splitFb(
        address[] memory venues,
        uint256[] memory hints,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 fallbackMinOut,
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
            fallbackMinOut,
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

    function test_split_belowMarketVenueIsCutOff() public {
        // A is uncapped and quotes linearly at 0.9 — strictly worse than
        // Uniswap's 1.0 at every size. This pins the reference-rate CUTOFF on
        // its own: a candidate that loses to Uniswap gets no leg at all, and
        // the whole order routes through the fallback.
        //
        // Deliberately built WITHOUT a cap: a saturated venue's surviving
        // candidate is resolved by the downward probe first, which would
        // entangle two mechanisms in one assertion. Saturation is pinned
        // separately by test_split_saturationDetectionKeepsHalfPointLeg and
        // the _probeDownToFillable tests below.
        MockCappedPropAMM a = _newVenue(10, 9, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(250e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);

        assertEq(amountOut, 250e18);
        assertEq(tokenIn.balanceOf(address(a)), 0, "a below-market venue must get no leg");
        assertEq(tokenOut.balanceOf(user), 250e18);
        _assertRouterEmpty();
    }

    function test_split_downwardProbeRecoversLiquidityFromASaturatedVenue() public {
        // The scenario the cutoff test used to carry: A pays 1.2 but fills
        // only 100 of a 250 order, so both probe points (250 and 125) return
        // its 120 ceiling. Read at the saturated half point its rate is
        // 120/125 = 0.96, which LOSES the Uniswap cutoff and earns A nothing
        // — the venue's real 1.2 liquidity is discarded entirely.
        //
        // Probing down to 62.5 (under the cap) quotes 75, a true 1.2 rate
        // that clears the cutoff and wins a leg. The mechanism that stops the
        // router overpaying a saturated venue also stops it from throwing
        // that venue's usable liquidity away.
        MockCappedPropAMM a = _newVenue(10, 12, 100e18, MockCappedPropAMM.CapMode.Saturate);
        _fundUser(250e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);

        // A: 62.5 -> 75. Remainder 187.5 -> Uniswap 1:1. Total 262.5.
        assertEq(tokenIn.balanceOf(address(a)), 62.5e18);
        assertEq(amountOut, 262.5e18);
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
            venues, _noHints(), address(opIn), address(tokenOut), 100e18, 0, 0, 8, user, block.timestamp + 1
        );

        // The whole call rolled back: the user still holds every wei.
        assertEq(opIn.balanceOf(user), 100e18);
        assertEq(opIn.balanceOf(address(router)), 0);
        assertEq(opIn.balanceOf(address(thief)), 0);
    }

    /// @dev `tokenIn == tokenOut` is a pair no venue can ever fill, so it must
    /// be rejected before the router pulls the funds and spends a two-quote
    /// probe per venue plus a QuoterV2 pool simulation planning a split for it.
    function test_split_identicalTokensRevertsBeforeQuoting() public {
        MockCappedPropAMM v = new MockCappedPropAMM(100, 100);
        tokenOut.mint(address(v), 1_000e18);
        vm.prank(owner);
        router.addVenue(address(v));

        tokenIn.mint(user, 100e18);
        vm.prank(user);
        tokenIn.approve(address(router), 100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(v);

        vm.expectCall(address(v), abi.encodeWithSelector(IPropAMM.quote.selector), 0);
        vm.prank(user);
        vm.expectRevert(IdenticalTokens.selector);
        router.swapSplitV1(
            venues, _noHints(), address(tokenIn), address(tokenIn), 100e18, 0, 0, 8, user, block.timestamp + 1
        );
    }

    function test_split_r1_donatingQuoteDoesNotBrickTheSplit() public {
        // R1 guards against the router LOSING tokenIn while it quotes. A venue
        // that hands the router 1 wei has taken nothing, so it must be priced
        // and ranked like any other venue rather than reverting the split for
        // every caller. The stray wei is recoverable via `rescueTokens`.
        MockDonatingQuoteVenue donor = new MockDonatingQuoteVenue();
        tokenIn.mint(address(donor), 10);

        MockCappedPropAMM good = new MockCappedPropAMM(100, 105);
        tokenOut.mint(address(good), 1_000e18);

        vm.startPrank(owner);
        router.addVenue(address(donor));
        router.addVenue(address(good));
        vm.stopPrank();

        tokenIn.mint(user, 100e18);
        vm.prank(user);
        tokenIn.approve(address(router), 100e18);

        address[] memory venues = new address[](2);
        venues[0] = address(donor);
        venues[1] = address(good);

        vm.prank(user);
        uint256 out = router.swapSplitV1(
            venues, _noHints(), address(tokenIn), address(tokenOut), 100e18, 0, 0, 8, user, block.timestamp + 1
        );

        assertEq(out, 105e18, "the good venue must still fill the whole order");
        assertEq(tokenIn.balanceOf(address(good)), 100e18, "and take the whole leg");
        assertGt(tokenIn.balanceOf(address(router)), 0, "the donated wei is stranded, awaiting rescueTokens");
    }

    function test_split_nonWhitelistedVenueNeverProbedAndCannotStarveRealVenues() public {
        // `_probeVenue` gates on `_isVenue` BEFORE the ERC165 branch, which
        // calls `quotePartialFill` directly rather than through
        // `quoteVenueV1`'s membership check. Without that gate a caller could
        // name any address that answers `supportsInterface`, have the router
        // execute its code while holding the pulled funds, and let it return
        // a maximal quote to sweep the ranking and starve the real venues.
        //
        // X is NOT whitelisted and advertises the partial-fill extension at a
        // fantastic x10 with unlimited capacity; B is whitelisted at x1.1.
        // Order = 250.
        MockPartialFillPropAMM x = new MockPartialFillPropAMM(1, 10);
        tokenOut.mint(address(x), 1_000_000e18);
        MockCappedPropAMM b = _newVenue(10, 11, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(250e18);
        assertFalse(router.isWhitelistedVenue(address(x)), "premise: X is not whitelisted");

        address[] memory venues = new address[](2);
        venues[0] = address(x);
        venues[1] = address(b);

        // The gate short-circuits ahead of the extension call, so the router
        // never executes X's code at all.
        vm.expectCall(
            address(x),
            abi.encodeCall(MockPartialFillPropAMM.quotePartialFill, (address(tokenIn), address(tokenOut), 250e18)),
            0
        );

        uint256 amountOut = _split(venues, _noHints(), 250e18, 0, 8);

        // X skipped entirely; B takes the whole order: 250 * 1.1 = 275.
        //
        // Decisive by construction: without the gate X would rank first at
        // x10, take the entire 250e18 leg, leave B nothing, then fail
        // `_dispatchVenue`'s whitelist check and coalesce into Uniswap for a
        // total of 250e18 with B paid nothing. Both assertions separate the
        // two outcomes.
        assertEq(amountOut, 275e18);
        assertEq(tokenIn.balanceOf(address(b)), 250e18);
        assertEq(tokenIn.balanceOf(address(x)), 0);
        assertEq(tokenOut.balanceOf(user), 275e18);
        _assertRouterEmpty();
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
            venues, _noHints(), address(tokenIn), address(tokenOut), 100e18, 121e18, 0, 8, user, block.timestamp + 1
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
        router.swapSplitV1(
            none, _noHints(), address(tokenIn), address(tokenOut), 1e18, 0, 0, 8, user, block.timestamp + 1
        );
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
        router.swapSplitV1(none, hints, address(tokenIn), address(tokenOut), 1e18, 0, 0, 8, user, block.timestamp + 1);
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
        router.swapSplitV1(venues, hints, address(tokenIn), address(tokenOut), 1e18, 0, 0, 8, user, block.timestamp + 1);
        assertEq(tokenIn.balanceOf(user), 1e18);
        _assertRouterEmpty();
    }

    function test_split_amountAboveUint128Reverts() public {
        _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        uint256 huge = uint256(type(uint128).max) + 1;
        address[] memory none = new address[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AmountTooLarge.selector, huge));
        router.swapSplitV1(
            none, _noHints(), address(tokenIn), address(tokenOut), huge, 0, 0, 8, user, block.timestamp + 1
        );
    }

    function test_split_zeroMaxLegsReverts() public {
        _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        address[] memory none = new address[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidMaxLegs.selector, 0));
        router.swapSplitV1(
            none, _noHints(), address(tokenIn), address(tokenOut), 1e18, 0, 0, 0, user, block.timestamp + 1
        );
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

    function test_splitWithFee_skimsAggregate() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 gross = 120e18;
        uint256 fee = gross * 50 / 10_000;
        uint256 net = gross - fee;

        vm.prank(user);
        uint256 amountOut = router.swapSplitWithFeeV1(
            venues,
            _noHints(),
            address(tokenIn),
            address(tokenOut),
            100e18,
            net,
            0,
            8,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, net);
        assertEq(tokenOut.balanceOf(user), net);
        assertEq(tokenOut.balanceOf(feeRecipient), fee);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    /// @dev `swapSplitWithFeeV1` treats `fallbackMinOut` as a NET minimum and
    /// grosses it up by `fee.bps`, matching `amountOutMin`. The whole 100e18
    /// goes through the coalesced Uniswap leg (no venues named), Uniswap pays
    /// 1:1, so the slice delivers a gross 100e18. A net floor of 100e18 needs
    /// gross ceil(100e18 * 10000/9950) = 100.502...e18 and must revert; 99e18
    /// net needs 99.497...e18 gross and must pass.
    function test_splitWithFee_fallbackMinOutIsNetBasis() public {
        address[] memory none = new address[](0);

        _fundUser(100e18);
        vm.prank(user);
        vm.expectRevert(); // MockLinearSwapRouter's own "uni-slippage"
        router.swapSplitWithFeeV1(
            none,
            _noHints(),
            address(tokenIn),
            address(tokenOut),
            100e18,
            0,
            100e18,
            8,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        _fundUser(100e18);
        vm.prank(user);
        uint256 amountOut = router.swapSplitWithFeeV1(
            none,
            _noHints(),
            address(tokenIn),
            address(tokenOut),
            100e18,
            0,
            99e18,
            8,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );
        assertEq(amountOut, 100e18 - (100e18 * 50 / 10_000), "net of the 50bp fee");
        _assertRouterEmpty();
    }

    /// @dev `isSplitWhitelistModeAvailable` must track the bound that
    /// `_resolveVenueSet` enforces, so an admin can see the empty-`venues`
    /// convenience path go away BEFORE it starts reverting for users. Pairs
    /// with `test_split_whitelistLargerThanMaxReverts`, which pins the revert.
    function test_split_whitelistModeAvailabilityTracksTheBound() public {
        assertTrue(router.isSplitWhitelistModeAvailable(), "empty whitelist is within the bound");

        for (uint256 i = 0; i < 8; i++) {
            _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
            assertTrue(router.isSplitWhitelistModeAvailable(), "at or below MAX_SPLIT_VENUES");
        }

        // The ninth is the one that bricks the convenience path.
        _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        assertFalse(router.isSplitWhitelistModeAvailable(), "past MAX_SPLIT_VENUES");

        // And it really does revert, while an explicit venue list still works.
        _fundUser(1e18);
        address[] memory none = new address[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TooManyVenues.selector, 9));
        router.swapSplitV1(
            none, _noHints(), address(tokenIn), address(tokenOut), 1e18, 0, 0, 8, user, block.timestamp + 1
        );

        address[] memory explicitOne = new address[](1);
        explicitOne[0] = router.whitelistedVenueAt(0);
        vm.prank(user);
        router.swapSplitV1(
            explicitOne, _noHints(), address(tokenIn), address(tokenOut), 1e18, 0, 0, 8, user, block.timestamp + 1
        );
        _assertRouterEmpty();
    }

    /// @dev The reason `fallbackMinOut` is pro-rated rather than absolute: the
    /// PLANNER decides how big the coalesced slice is, not the caller. Here a
    /// caller simulates offchain while venue B is stale (per Phase 0, most
    /// venues are stale at any given block), sees A take 300e18 with a 700e18
    /// Uniswap remainder, and prices the floor for the full 1000e18 input. By
    /// execution B has published, the planner uses it, and the remainder
    /// shrinks to 400e18. An ABSOLUTE floor priced for 700e18 would revert
    /// this — a strictly BETTER split than the one simulated. The pro-rated
    /// floor scales with the slice, so it goes through.
    function test_split_fallbackFloorSurvivesAShrinkingRemainder() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        MockCappedPropAMM b = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);
        uint256[] memory hints = new uint256[](2);
        hints[0] = 300e18;
        hints[1] = 300e18;

        // Uniswap pays 1:1, so a full-order floor with 1% slack is 990e18.
        uint256 fallbackMinOut = 1000e18 * 99 / 100;

        // The caller's simulation: B stale, so the remainder is 700e18.
        b.setActive(false);
        _fundUser(1000e18);
        uint256 simulated = _splitFb(venues, hints, 1000e18, 0, fallbackMinOut, 8);

        // Execution: B is live, takes 300e18, and the remainder is now 400e18.
        b.setActive(true);
        _fundUser(1000e18);
        uint256 executed = _splitFb(venues, hints, 1000e18, 0, fallbackMinOut, 8);

        assertGt(executed, simulated, "the live-B split must be strictly better");
        assertEq(executed, 720e18 + 400e18, "two 300e18 legs at 1.2 plus a 400e18 Uniswap remainder");
        _assertRouterEmpty();
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_split_alwaysMeetsMinOrReverts(uint96 rawAmount, uint64 capA, uint8 modeA, uint64 rateBpsA)
        public
    {
        uint256 amountIn = bound(uint256(rawAmount), 1e6, 1_000_000e18);
        uint256 rate = bound(uint256(rateBpsA), 5_000, 20_000); // 0.5x .. 2.0x
        // `capA` fuzzed raw as a uint64 makes the uncapped case (cap == 0)
        // vanishingly unlikely to ever be sampled. Force it to occur on
        // roughly a quarter of runs (the rest keep a bounded non-zero cap),
        // since cap == 0 combined with rate > 1.0 is the one sub-case below
        // where the planner's output is fully determined and worth pinning
        // exactly, rather than only checking the safety floor.
        uint256 cap = capA % 4 == 0 ? 0 : bound(uint256(capA), 1, 1_000_000e18);
        MockCappedPropAMM a = _newVenue(10_000, rate, cap, MockCappedPropAMM.CapMode(modeA % 3));
        _fundUser(amountIn);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        // Uniswap 1:1 floor: whatever the venue does, the split can always
        // deliver >= amountIn via the fallback, so demand exactly that.
        vm.prank(user);
        uint256 amountOut = router.swapSplitV1(
            venues, _noHints(), address(tokenIn), address(tokenOut), amountIn, amountIn, 0, 8, user, block.timestamp + 1
        );
        assertGe(amountOut, amountIn);
        assertEq(tokenIn.balanceOf(address(router)), 0); // nothing stranded
        assertEq(tokenIn.balanceOf(user), 0);

        // CAPABILITY: an uncapped venue priced strictly above 1.0 quotes
        // exactly linearly at both probe points, so it never saturates, wins
        // the reference cutoff outright, and takes ONE leg for the entire
        // amountIn with no remainder leg. The total is then pinned exactly —
        // this is the sub-case that collapses to `amountIn` (the safety
        // floor above, satisfied vacuously) if the prop-venue planning path
        // were deleted, so it is the one worth asserting precisely.
        if (cap == 0 && rate > 10_000) {
            assertEq(amountOut, amountIn * rate / 10_000, "uncapped above-market venue must capture the whole order");
        }
    }

    //-----------------//
    // ETH sentinel    //
    //-----------------//

    /// @dev Etches MockWETH's code at the hardcoded mainnet WETH address and
    /// deals it ETH to service withdrawals. Mirrors
    /// `PropAMMRouterMultiLegTest._etchWETH`. `vm.etch` copies code only
    /// (not storage), so the etched account's ERC20 metadata is empty —
    /// harmless, since the tests below never read name/symbol/decimals.
    function _etchWETH() internal {
        MockWETH impl = new MockWETH();
        vm.etch(WETH, address(impl).code);
        vm.deal(WETH, 100 ether);
    }

    function test_split_ethIn_wrapsAndVenueTakesWholeOrder() public {
        // Uncapped x1.2 venue: exactly like the fuzz capability case, it
        // beats the 1:1 fallback outright and takes the whole order as one
        // leg. `_pullFunds` wraps the incoming ETH to WETH before any
        // quoting happens, so this also exercises the `tokenOut_ = ...`
        // resolution feeding every quote in the split.
        _etchWETH();
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        vm.deal(user, 100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        vm.prank(user);
        uint256 amountOut = router.swapSplitV1{value: 100e18}(
            venues, _noHints(), ETH_SENTINEL, address(tokenOut), 100e18, 0, 0, 8, user, block.timestamp + 1
        );

        assertEq(amountOut, 120e18);
        assertEq(IERC20(WETH).balanceOf(address(a)), 100e18, "venue did not receive the wrapped ETH");
        assertEq(tokenOut.balanceOf(user), 120e18);
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router retained WETH");
        _assertRouterEmpty();
    }

    function test_split_ethIn_wrongValueReverts() public {
        _etchWETH();
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        vm.deal(user, 10 ether);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, 5 ether, 3 ether));
        router.swapSplitV1{value: 3 ether}(
            venues, _noHints(), ETH_SENTINEL, address(tokenOut), 5 ether, 0, 0, 8, user, block.timestamp + 1
        );
    }

    function test_split_ethOut_unwrapsAndSendsRawETH() public {
        // The venue must deliver WETH (the resolved tokenOut_), so it is
        // funded with WETH directly rather than through `_newVenue` (which
        // mints the ERC20 mock `tokenOut`). Asserts the user's NATIVE
        // balance increases by the full amount, not a WETH balance standing
        // in for it, and that the router ends up holding neither.
        _etchWETH();
        MockCappedPropAMM a = new MockCappedPropAMM(10, 12);
        vm.deal(address(this), 1_000e18);
        IWETH(WETH).deposit{value: 1_000e18}();
        IERC20(WETH).transfer(address(a), 1_000e18);
        vm.prank(owner);
        router.addVenue(address(a));
        _fundUser(100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 balBefore = user.balance;
        vm.prank(user);
        uint256 amountOut = router.swapSplitV1(
            venues, _noHints(), address(tokenIn), ETH_SENTINEL, 100e18, 0, 0, 8, user, block.timestamp + 1
        );

        assertEq(amountOut, 120e18);
        assertEq(user.balance - balBefore, 120e18, "user did not receive the full native ETH amount");
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router retained WETH");
        _assertRouterEmpty();
    }

    //------------------//
    // Validation gaps  //
    //------------------//

    function test_split_revertsPastDeadline() public {
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        address[] memory venues = new address[](1);
        venues[0] = address(a);

        vm.prank(user);
        vm.expectRevert(Expired.selector);
        router.swapSplitV1(
            venues, _noHints(), address(tokenIn), address(tokenOut), 100e18, 0, 0, 8, user, block.timestamp - 1
        );
    }

    function test_split_revertsWhenPaused() public {
        // Fund the user BEFORE pausing so the pause check is the only
        // reachable revert — an unfunded account would satisfy a bare
        // `expectRevert()` via a plain ERC20 allowance failure instead.
        MockCappedPropAMM a = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);
        vm.prank(owner);
        router.pause();

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        router.swapSplitV1(
            venues, _noHints(), address(tokenIn), address(tokenOut), 100e18, 0, 0, 8, user, block.timestamp + 1
        );
    }

    //--------------------------------------//
    // Quote integrity (review findings)    //
    //--------------------------------------//

    function test_split_partialFillOverReportingVenueIsRejected() public {
        // A implements IPropAMMPartialFill but violates its "fillableAmountIn
        // MUST be <= amountIn" requirement, reporting DOUBLE the order with
        // the amountOut for that doubled fill. Clamping the fill without
        // rescaling the output would read A's rate as 2.4 (vs its real 1.2),
        // rank it first, hand it the whole order at an unmeetable minOut, and
        // starve B — whose 1.5 is the best real rate available.
        MockPartialFillPropAMM a = new MockPartialFillPropAMM(10, 12);
        a.setOverReportFactor(2);
        tokenOut.mint(address(a), 1_000_000e18);
        vm.prank(owner);
        router.addVenue(address(a));
        MockCappedPropAMM b = _newVenue(10, 15, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);

        uint256 amountOut = _split(venues, _noHints(), 100e18, 0, 8);

        // A's quote is discarded outright, so B takes the whole order at 1.5.
        assertEq(amountOut, 150e18);
        assertEq(tokenIn.balanceOf(address(b)), 100e18, "B must not be starved by an over-reported quote");
        assertEq(tokenIn.balanceOf(address(a)), 0, "over-reporting venue must get no leg");
        _assertRouterEmpty();
    }

    function test_split_partialFillExtensionHonorsProbeHint() public {
        // A is uncapped, so left to itself it reports the whole order as
        // fillable and takes it. The caller's hint bounds its exposure to 25:
        // the hint must reach `quotePartialFill`, not just the two-point
        // probe. Total output is LOWER than the unhinted plan on purpose —
        // the hint is the caller's instruction, not an optimization.
        MockPartialFillPropAMM a = new MockPartialFillPropAMM(10, 12);
        tokenOut.mint(address(a), 1_000_000e18);
        vm.prank(owner);
        router.addVenue(address(a));
        MockCappedPropAMM b = _newVenue(10, 11, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);
        uint256[] memory hints = new uint256[](2);
        hints[0] = 25e18;

        uint256 amountOut = _split(venues, hints, 100e18, 0, 8);

        // A: 25 -> 30 (x1.2). B: 75 -> 82.5 (x1.1). Total 112.5.
        assertEq(tokenIn.balanceOf(address(a)), 25e18, "hint must bound the partial-fill venue's leg");
        assertEq(tokenIn.balanceOf(address(b)), 75e18);
        assertEq(amountOut, 112.5e18);
        _assertRouterEmpty();
    }

    function test_split_bothProbePointsSaturatedProbesDownForFillableSize() public {
        // A pays x3 but fills only 40, saturating above it. Order = 100, so
        // BOTH the full (100) and half (50) probes return the same ceiling
        // output of 120 — the half point is saturated too. Stepping down once
        // more finds 25, which is under the cap and quotes strictly below the
        // ceiling, so 25 is a size A demonstrably fills.
        //
        // Decisive by construction: sizing A at the saturated half point
        // hands it 50 while it only fills 40, and A KEEPS the unfilled 10
        // (see MockCappedPropAMM.swap in Saturate mode). That plan delivers
        // 120 + 50*2 = 220; sizing A at a fillable 25 delivers 75 + 75*2 =
        // 225, because the 25 that A cannot fill earns B's rate instead.
        MockCappedPropAMM a = _newVenue(10, 30, 40e18, MockCappedPropAMM.CapMode.Saturate);
        MockCappedPropAMM b = _newVenue(10, 20, 0, MockCappedPropAMM.CapMode.HardRevert);
        _fundUser(100e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);

        uint256 amountOut = _split(venues, _noHints(), 100e18, 0, 8);

        assertEq(tokenIn.balanceOf(address(a)), 25e18, "A must only be handed a size it fills");
        assertEq(tokenIn.balanceOf(address(b)), 75e18);
        assertEq(amountOut, 225e18);
        _assertRouterEmpty();
    }

    function test_split_unsizeableSaturatedVenueGetsNoLeg() public {
        // A's cap (1) is so far below the order (100) that every probe in the
        // downward budget still returns its ceiling output: the router can
        // never establish a size A actually fills. It must then decline A
        // rather than hand it a leg whose unfilled excess A would keep.
        //
        // This is the conservative branch of the policy: A's saturated quote
        // looks attractive (its ceiling beats Uniswap outright, which is the
        // only reason it survives the reference cutoff at all), and declining
        // it costs output. The router still declines, because the alternative
        // is paying a venue for input it will not fill.
        MockCappedPropAMM a = _newVenue(1, 1000, 1e18, MockCappedPropAMM.CapMode.Saturate);
        _fundUser(100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        uint256 amountOut = _split(venues, _noHints(), 100e18, 0, 8);

        assertEq(tokenIn.balanceOf(address(a)), 0, "unsizeable venue must be handed nothing");
        assertEq(amountOut, 100e18, "whole order routes through the fallback at 1:1");
        _assertRouterEmpty();
    }

    function test_split_r1InvariantBracketsWaterfallReferenceQuotes() public {
        // The R1 invariant must cover EVERY quote taken while the router
        // holds the pulled funds, including `_waterfall`'s Uniswap reference
        // quotes. The candidate probes here go to a propAMM, so the thieving
        // quoter is reached only from `_waterfall`.
        MockOperatorERC20 opIn = new MockOperatorERC20("OpIn", "OPIN");
        MockThievingQuoterV2 thief = new MockThievingQuoterV2(address(opIn));
        opIn.setOperator(address(thief));

        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(thief), address(manager)));
        PropAMMRouter r = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), data))));

        MockCappedPropAMM a = new MockCappedPropAMM(10, 12);
        tokenOut.mint(address(a), 1_000_000e18);
        vm.prank(owner);
        r.addVenue(address(a));

        opIn.mint(user, 100e18);
        vm.prank(user);
        opIn.approve(address(r), 100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(a);

        vm.prank(user);
        vm.expectRevert(QuoteBalanceInvariantViolated.selector);
        r.swapSplitV1(venues, _noHints(), address(opIn), address(tokenOut), 100e18, 0, 0, 8, user, block.timestamp + 1);

        assertEq(opIn.balanceOf(user), 100e18);
        assertEq(opIn.balanceOf(address(r)), 0);
    }

    function test_split_emptyWhitelistRoutesToFallback() public {
        // No venues whitelisted and none named: economically identical to
        // naming a list whose every entry is dead, which routes the whole
        // order through Uniswap. Both must behave the same way.
        _fundUser(100e18);
        address[] memory none = new address[](0);

        uint256 amountOut = _split(none, _noHints(), 100e18, 0, 8);

        assertEq(amountOut, 100e18);
        assertEq(tokenOut.balanceOf(user), 100e18);
        _assertRouterEmpty();
    }

    function test_split_deadVenueListMatchesEmptyWhitelist() public {
        // The comparison arm of the test above: a named-but-unusable venue.
        MockCappedPropAMM dead = _newVenue(10, 12, 0, MockCappedPropAMM.CapMode.HardRevert);
        dead.setActive(false);
        _fundUser(100e18);

        address[] memory venues = new address[](1);
        venues[0] = address(dead);

        assertEq(_split(venues, _noHints(), 100e18, 0, 8), 100e18);
        _assertRouterEmpty();
    }

    function test_split_callerFallbackFloorGatesTheCoalescedSwap() public {
        // A (x2, cap 60) wins a 50 leg and alone covers `amountOutMin`, so
        // the aggregate shortfall collapses to zero. B then under-delivers
        // its own quote, fails its per-leg min, and its 50 coalesces into a
        // Uniswap swap that would otherwise carry NO floor at all. The
        // caller's `fallbackMinOut` is the only thing gating that slice.
        MockCappedPropAMM a = _newVenue(10, 20, 60e18, MockCappedPropAMM.CapMode.HardRevert);
        MockCappedPropAMM b = _newVenue(10, 15, 0, MockCappedPropAMM.CapMode.HardRevert);
        b.setShortChangeBps(5000); // delivers half its quote -> trips its per-leg min
        _fundUser(100e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);

        // Uniswap pays 1:1, so the 50 coalesced from B's failure yields 50.
        // `fallbackMinOut` is priced for the FULL 100e18 input and pro-rated
        // to the slice, so 120e18 becomes a 60e18 floor on the 50e18 slice —
        // unreachable, and it must revert.
        vm.prank(user);
        vm.expectRevert(bytes("uni-slippage"));
        router.swapSplitV1(
            venues,
            _noHints(),
            address(tokenIn),
            address(tokenOut),
            100e18,
            100e18,
            120e18,
            8,
            user,
            block.timestamp + 1
        );
    }

    function test_split_callerFallbackFloorAllowsReachableFloor() public {
        // Same plan, with a floor the coalesced swap can actually clear.
        MockCappedPropAMM a = _newVenue(10, 20, 60e18, MockCappedPropAMM.CapMode.HardRevert);
        MockCappedPropAMM b = _newVenue(10, 15, 0, MockCappedPropAMM.CapMode.HardRevert);
        b.setShortChangeBps(5000);
        _fundUser(100e18);

        address[] memory venues = new address[](2);
        venues[0] = address(a);
        venues[1] = address(b);

        uint256 amountOut = _splitFb(venues, _noHints(), 100e18, 100e18, 50e18, 8);

        // A: 50 -> 100. B fails, its 50 coalesces to Uniswap 1:1 -> 50.
        assertEq(amountOut, 150e18);
        _assertRouterEmpty();
    }
}
