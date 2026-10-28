// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPropAMM} from "./mocks/MockPropAMM.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";

/// @dev Which swap event each entrypoint emits, and what its routing fields say
/// when the requested venue fills and when the fallback runs instead.
contract PropAMMRouterEventsTest is Test {
    PropAMMRouter router;
    AccessManager manager;
    MockV3SwapRouter swapRouter;
    MockQuoterV2 quoter;
    MockPropAMM venue;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address feeRecipient = makeAddr("feeRecipient");

    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant MIN_OUT = 990e18;
    uint256 constant VENUE_OUT = 1_000e18;

    function setUp() public {
        swapRouter = new MockV3SwapRouter();
        quoter = new MockQuoterV2();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");

        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data =
            abi.encodeCall(PropAMMRouter.initialize, (address(swapRouter), address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), data))));

        // One whitelisted propAMM that quotes and fills VENUE_OUT; the Uniswap
        // fallback delivers exactly MIN_OUT. A test under-fills the propAMM to
        // force the fallback.
        venue = new MockPropAMM();
        venue.setQuote(VENUE_OUT);
        venue.setAmountOut(VENUE_OUT);
        vm.prank(owner);
        router.addVenue(address(venue));

        tokenOut.mint(address(swapRouter), MIN_OUT);
        swapRouter.setAmountOut(MIN_OUT);
        quoter.setQuote(MIN_OUT);

        tokenIn.mint(user, AMOUNT_IN);
        vm.prank(user);
        tokenIn.approve(address(router), AMOUNT_IN);
    }

    function _selected() internal view returns (address[] memory venues) {
        venues = new address[](1);
        venues[0] = address(venue);
    }

    /// @dev The swap logs the router emitted in the recorded run, by topic0.
    function _routerSwapTopics(Vm.Log[] memory logs) internal view returns (bytes32[] memory topics) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && _isSwapTopic(logs[i].topics[0])) n++;
        }
        topics = new bytes32[](n);
        uint256 j;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && _isSwapTopic(logs[i].topics[0])) topics[j++] = logs[i].topics[0];
        }
    }

    function _isSwapTopic(bytes32 topic) internal pure returns (bool) {
        return topic == IPropAMMRouter.Swapped.selector || topic == IPropAMMRouter.SwappedViaVenue.selector
            || topic == IPropAMMRouter.SwappedViaSelectedVenues.selector;
    }

    // --- swapV1: the router picked, Swapped as before --------------------

    function test_swapV1_venueFill_emitsSwapped() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.Swapped(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, VENUE_OUT, user, address(venue)
        );

        vm.prank(user);
        router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1);
    }

    function test_swapV1_emitsExactlyOneSwapEvent() public {
        vm.recordLogs();
        vm.prank(user);
        router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1);

        bytes32[] memory topics = _routerSwapTopics(vm.getRecordedLogs());
        assertEq(topics.length, 1);
        assertEq(topics[0], IPropAMMRouter.Swapped.selector);
    }

    // --- swapViaVenueV1: SwappedViaVenue carries the pinned venue ---------

    function test_swapViaVenueV1_venueFill_emitsSwappedViaVenue() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaVenue(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, VENUE_OUT, user, address(venue), address(venue)
        );

        vm.prank(user);
        router.swapViaVenueV1(
            address(venue), address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1
        );
    }

    /// @dev The pinned venue under-fills, so the fallback runs: `venue` keeps the
    /// request and `marketMaker` says who actually filled.
    function test_swapViaVenueV1_fallback_emitsSwappedViaVenue_withPinnedVenue() public {
        venue.setAmountOut(1);

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaVenue(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, address(swapRouter), address(venue)
        );

        vm.prank(user);
        (, address executedVenue) = router.swapViaVenueV1(
            address(venue), address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1
        );
        assertEq(executedVenue, address(swapRouter));
    }

    /// @dev Pinning the fallback itself is a valid request; both fields name it.
    function test_swapViaVenueV1_pinnedFallback_emitsSwappedViaVenue() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaVenue(
            user,
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            MIN_OUT,
            user,
            address(swapRouter),
            address(swapRouter)
        );

        vm.prank(user);
        router.swapViaVenueV1(
            address(swapRouter), address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1
        );
    }

    function test_swapViaVenueV1_emitsNoPlainSwapped() public {
        vm.recordLogs();
        vm.prank(user);
        router.swapViaVenueV1(
            address(venue), address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1
        );

        bytes32[] memory topics = _routerSwapTopics(vm.getRecordedLogs());
        assertEq(topics.length, 1);
        assertEq(topics[0], IPropAMMRouter.SwappedViaVenue.selector);
    }

    /// @dev The fee variant logs the NET amount, like `swapWithFeeV1` does on `Swapped`.
    function test_swapViaVenueWithFeeV1_emitsSwappedViaVenue_netAmount() public {
        uint256 expectedFee = VENUE_OUT * 50 / 10_000;
        uint256 expectedNet = VENUE_OUT - expectedFee;

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaVenue(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, expectedNet, user, address(venue), address(venue)
        );

        vm.prank(user);
        uint256 amountOut = router.swapViaVenueWithFeeV1(
            address(venue),
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            expectedNet,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );
        assertEq(amountOut, expectedNet);
    }

    // --- swapViaSelectedVenuesV1: SwappedViaSelectedVenues carries the list --

    function test_swapViaSelectedVenuesV1_venueFill_emitsSwappedViaSelectedVenues() public {
        address[] memory venues = _selected();

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaSelectedVenues(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, VENUE_OUT, user, address(venue), venues
        );

        vm.prank(user);
        router.swapViaSelectedVenuesV1(
            venues, address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1
        );
    }

    function test_swapViaSelectedVenuesV1_fallback_emitsSwappedViaSelectedVenues_withCandidates() public {
        venue.setAmountOut(1);
        address[] memory venues = _selected();

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaSelectedVenues(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, address(swapRouter), venues
        );

        vm.prank(user);
        (, address executedVenue) = router.swapViaSelectedVenuesV1(
            venues, address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, user, block.timestamp + 1
        );
        assertEq(executedVenue, address(swapRouter));
    }

    function test_swapViaSelectedVenuesWithFeeV1_emitsSwappedViaSelectedVenues_netAmount() public {
        uint256 expectedFee = VENUE_OUT * 50 / 10_000;
        uint256 expectedNet = VENUE_OUT - expectedFee;
        address[] memory venues = _selected();

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.SwappedViaSelectedVenues(
            user, address(tokenIn), address(tokenOut), AMOUNT_IN, expectedNet, user, address(venue), venues
        );

        vm.prank(user);
        (uint256 amountOut,) = router.swapViaSelectedVenuesWithFeeV1(
            venues,
            address(tokenIn),
            address(tokenOut),
            AMOUNT_IN,
            expectedNet,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );
        assertEq(amountOut, expectedNet);
    }
}
