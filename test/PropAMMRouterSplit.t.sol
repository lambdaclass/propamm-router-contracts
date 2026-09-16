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
import {MockPropAMM} from "./mocks/MockPropAMM.sol";
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
