// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockLinearSwapRouter, MockLinearQuoterV2} from "./mocks/MockLinearUniswap.sol";

/// @notice Execution-gas comparison across the swap entrypoints at 1..4 legs.
///
/// Method: every case is run TWICE and only the second run is measured, so all
/// numbers are warm-storage. Measurement is `gasleft()` either side of the
/// external call, which counts the CALL and everything under it but EXCLUDES
/// the 21,000 intrinsic tx cost and per-byte calldata cost.
///
/// Absolute numbers are mock-venue numbers, not mainnet ones: `MockCappedPropAMM`
/// quotes and swaps far more cheaply than a real registry-priced venue (Phase 0
/// measured 32-74k per real quote alone). What transfers to mainnet is the
/// SHAPE — router overhead per leg, and the planner's quote count.
contract GasBenchTest is Test {
    PropAMMRouter router;
    MockLinearSwapRouter uni;
    MockLinearQuoterV2 quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockCappedPropAMM[4] venues;
    address fallbackRouter;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address feeRecipient = makeAddr("feeRecipient");

    // Divisible by 1,2,3,4 so `AMOUNT/n` legs sum EXACTLY to AMOUNT at every
    // leg count. With 1000e18, n=3 left a 1-wei remainder, which appended a
    // whole extra coalesced Uniswap leg and made n=3 dearer than n=4.
    uint256 constant AMOUNT = 1_200e18;

    function setUp() public {
        uni = new MockLinearSwapRouter();
        quoter = new MockLinearQuoterV2();
        uni.setPrice(1, 1); // Uniswap pays 1.0
        quoter.setPrice(1, 1);
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        AccessManager m = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        router = PropAMMRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(quoter), address(m)))
                    )
                ))
        );
        fallbackRouter = router.fallbackSwapRouter();
        // Four identical venues paying 1.2 -- all beat Uniswap, so the split
        // planner's rate cutoff admits every one of them.
        for (uint256 i = 0; i < 4; i++) {
            venues[i] = new MockCappedPropAMM(10, 12);
            venues[i].setCap(0);
            tokenOut.mint(address(venues[i]), 1_000_000_000e18);
            vm.prank(owner);
            router.addVenue(address(venues[i]));
        }
    }

    function _fund() internal {
        tokenIn.mint(user, AMOUNT);
        vm.prank(user);
        tokenIn.approve(address(router), AMOUNT);
    }

    function _venueList(uint256 n) internal view returns (address[] memory list) {
        list = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            list[i] = address(venues[i]);
        }
    }

    function _legs(uint256 n) internal view returns (IPropAMMRouter.Leg[] memory legs) {
        legs = new IPropAMMRouter.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = IPropAMMRouter.Leg({venue: address(venues[i]), amountIn: AMOUNT / n, minOut: 0});
        }
    }

    /// @dev Hints sized so each venue's candidate fill is exactly AMOUNT/n, so
    /// the waterfall assigns n prop legs and leaves zero remainder.
    function _hints(uint256 n) internal pure returns (uint256[] memory h) {
        h = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            h[i] = AMOUNT / n;
        }
    }

    // ---- measured shapes -------------------------------------------------

    function _runMultiLeg(uint256 n) internal returns (uint256 gas) {
        IPropAMMRouter.Leg[] memory legs = _legs(n);
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
        gas = g - gasleft();
        vm.stopPrank();
    }

    function _runMultiLegFee(uint256 n) internal returns (uint256 gas) {
        IPropAMMRouter.Leg[] memory legs = _legs(n);
        IPropAMMRouter.FrontendFee memory fee = IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient});
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapMultiLegWithFeeV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1, fee);
        gas = g - gasleft();
        vm.stopPrank();
    }

    function _runSplit(uint256 n) internal returns (uint256 gas) {
        address[] memory vl = _venueList(n);
        uint256[] memory h = _hints(n);
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapSplitV1(vl, h, address(tokenIn), address(tokenOut), AMOUNT, 0, 0, 8, user, block.timestamp + 1);
        gas = g - gasleft();
        vm.stopPrank();
    }

    function _runSplitFee(uint256 n) internal returns (uint256 gas) {
        address[] memory vl = _venueList(n);
        uint256[] memory h = _hints(n);
        IPropAMMRouter.FrontendFee memory fee = IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient});
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapSplitWithFeeV1(
            vl, h, address(tokenIn), address(tokenOut), AMOUNT, 0, 0, 8, user, block.timestamp + 1, fee
        );
        gas = g - gasleft();
        vm.stopPrank();
    }

    function _runSelected(uint256 n) internal returns (uint256 gas) {
        address[] memory vl = _venueList(n);
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapViaSelectedVenuesV1(vl, address(tokenIn), address(tokenOut), AMOUNT, 0, user, block.timestamp + 1);
        gas = g - gasleft();
        vm.stopPrank();
    }

    function _runUniViaRouter() internal returns (uint256 gas) {
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapViaVenueV1(fallbackRouter, address(tokenIn), address(tokenOut), AMOUNT, 0, user, block.timestamp + 1);
        gas = g - gasleft();
        vm.stopPrank();
    }

    function _runSwapV1() internal returns (uint256 gas) {
        _fund();
        vm.startPrank(user);
        uint256 g = gasleft();
        router.swapV1(address(tokenIn), address(tokenOut), AMOUNT, 0, user, block.timestamp + 1);
        gas = g - gasleft();
        vm.stopPrank();
    }

    // ---- report ----------------------------------------------------------

    function test_gasComparison() public {
        // Warm every shape at every leg count first. State persists between
        // calls in a single test function, so a cold first touch of venue #k
        // or of a token balance slot would otherwise be charged to whichever
        // measurement happened to reach it first.
        for (uint256 w = 1; w <= 4; w++) {
            _runMultiLeg(w);
            _runMultiLegFee(w);
            _runSplit(w);
            _runSplitFee(w);
            _runSelected(w);
        }
        _runUniViaRouter();
        _runSwapV1();

        uint256[5] memory ml;
        uint256[5] memory mlf;
        uint256[5] memory sp;
        uint256[5] memory spf;
        uint256[5] memory sel;
        for (uint256 n = 1; n <= 4; n++) {
            ml[n] = _runMultiLeg(n);
            mlf[n] = _runMultiLegFee(n);
            sp[n] = _runSplit(n);
            spf[n] = _runSplitFee(n);
            sel[n] = _runSelected(n);
        }
        uint256 uniRouter = _runUniViaRouter();
        uint256 swapv1 = _runSwapV1();

        console2.log("=== BASELINES (leg-count independent) ===");
        console2.log("swapViaVenueV1 -> Uniswap fallback ", uniRouter);
        console2.log("swapV1 (quotes whole 4-venue list) ", swapv1);
        console2.log("");
        console2.log("=== BY LEG COUNT ===");
        for (uint256 n = 1; n <= 4; n++) {
            console2.log("--- legs:", n);
            console2.log("  swapMultiLegV1        ", ml[n]);
            console2.log("  swapSplitV1           ", sp[n]);
            console2.log("  swapViaSelectedVenues ", sel[n]);
            console2.log("  swapMultiLegWithFeeV1 ", mlf[n]);
            console2.log("  swapSplitWithFeeV1    ", spf[n]);
        }
        console2.log("");
        console2.log("=== MARGINAL COST PER ADDED LEG ===");
        for (uint256 n = 2; n <= 4; n++) {
            console2.log("--- legs:", n);
            console2.log("  swapMultiLegV1 delta  ", int256(ml[n]) - int256(ml[n - 1]));
            console2.log("  swapSplitV1 delta     ", int256(sp[n]) - int256(sp[n - 1]));
            console2.log("  selectedVenues delta  ", int256(sel[n]) - int256(sel[n - 1]));
        }
        console2.log("");
        console2.log("=== PLANNER PREMIUM (swapSplitV1 - swapMultiLegV1) ===");
        for (uint256 n = 1; n <= 4; n++) {
            console2.log("  legs / premium", n, sp[n] - ml[n]);
        }
        console2.log("");
        console2.log("=== FEE-SKIM PREMIUM ===");
        for (uint256 n = 1; n <= 4; n++) {
            console2.log("  legs / multileg / split", n, mlf[n] - ml[n], spf[n] - sp[n]);
        }

        // Structural assertions only. Absolute gas moves with the compiler and
        // the gas schedule, so pinning numbers here would be noise; these are
        // relationships that hold as long as the design does.
        for (uint256 n = 1; n <= 4; n++) {
            assertGt(sp[n], ml[n], "onchain planning must cost more than a caller-supplied plan");
            assertGt(mlf[n], ml[n], "fee skim must cost something");
            assertGt(spf[n], sp[n], "fee skim must cost something");
        }
        for (uint256 n = 2; n <= 4; n++) {
            // selectedVenues adds a quote per venue but still executes ONE leg;
            // multileg adds a whole venue swap plus an event per leg.
            assertLt(
                sel[n] - sel[n - 1],
                ml[n] - ml[n - 1],
                "quoting one more venue must be cheaper than executing one more leg"
            );
            // The planner premium grows with the venue count, because probing
            // is per-venue. If this ever goes flat the probe loop is not running.
            assertGt(sp[n] - ml[n], sp[n - 1] - ml[n - 1], "planner premium must grow per probed venue");
        }
        // A single-leg multileg skips the quote phase entirely, so it must beat
        // every entrypoint that quotes before executing.
        assertLt(ml[1], swapv1, "1-leg multileg must beat swapV1, which quotes the whole whitelist");
        assertLt(ml[1], sel[1], "1-leg multileg must beat selectedVenues, which quotes first");
    }
}
