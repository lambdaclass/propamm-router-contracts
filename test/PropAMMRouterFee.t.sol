// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter, FrontendFee} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {BEBOP_ROUTER} from "../src/interfaces/IBebopRouter.sol";
import {MockBebop} from "./mocks/MockBebop.sol";

contract PropAMMRouterFeeTest is Test {
    PropAMMRouter router;
    MockV3SwapRouter swapRouter;
    MockQuoterV2 quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address feeRecipient = makeAddr("feeRecipient");

    function _deployRouter() internal returns (PropAMMRouter) {
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data = abi.encodeCall(
            PropAMMRouter.initialize, (address(swapRouter), address(quoter), owner)
        );
        return PropAMMRouter(address(new ERC1967Proxy(address(impl), data)));
    }

    function setUp() public {
        swapRouter = new MockV3SwapRouter();
        quoter = new MockQuoterV2();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        router = _deployRouter();
    }

    // Funds the user with tokenIn, pre-funds the mock swap router with tokenOut to
    // deliver, sets the quote + delivered amount, and approves the router.
    function _prepare(uint256 amountIn, uint256 delivered) internal {
        tokenIn.mint(user, amountIn);
        tokenOut.mint(address(swapRouter), delivered);
        swapRouter.setAmountOut(delivered);
        quoter.setQuote(delivered);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
    }

    // feeBps = 50 (0.5%); delivered 1_000e18 -> fee 5e18, user 995e18.
    function test_swapWithFee_takesFeeAndPaysUser() public {
        _prepare(1_000e18, 1_000e18);
        uint256 expectedFee = 1_000e18 * 50 / 10_000; // 5e18
        uint256 expectedNet = 1_000e18 - expectedFee; // 995e18

        vm.prank(user);
        (uint256 amountOut, address executedVenue) = router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, expectedNet,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, expectedNet);
        assertEq(executedVenue, address(swapRouter));
        assertEq(tokenOut.balanceOf(user), expectedNet);
        assertEq(tokenOut.balanceOf(feeRecipient), expectedFee);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    function test_swapViaVenueWithFee_fallback_takesFee() public {
        _prepare(1_000e18, 1_000e18);
        uint256 expectedFee = 1_000e18 * 50 / 10_000;
        uint256 expectedNet = 1_000e18 - expectedFee;

        vm.prank(user);
        uint256 amountOut = router.swapViaVenueWithFeeV1(
            address(swapRouter), // the fallback venue address is a valid venue
            address(tokenIn), address(tokenOut), 1_000e18, expectedNet,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, expectedNet);
        assertEq(tokenOut.balanceOf(user), expectedNet);
        assertEq(tokenOut.balanceOf(feeRecipient), expectedFee);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    function test_swapViaSelectedVenuesWithFee_takesFee() public {
        _prepare(1_000e18, 1_000e18);
        uint256 expectedFee = 1_000e18 * 50 / 10_000;
        uint256 expectedNet = 1_000e18 - expectedFee;

        address[] memory venues = new address[](1);
        venues[0] = address(swapRouter); // the fallback venue, only priceable candidate

        vm.prank(user);
        (uint256 amountOut, address executedVenue) = router.swapViaSelectedVenuesWithFeeV1(
            venues, address(tokenIn), address(tokenOut), 1_000e18, expectedNet,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, expectedNet);
        assertEq(executedVenue, address(swapRouter));
        assertEq(tokenOut.balanceOf(user), expectedNet);
        assertEq(tokenOut.balanceOf(feeRecipient), expectedFee);
    }

    function test_swapWithFee_revertsFeeTooHigh() public {
        _prepare(1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.FeeBpsTooHigh.selector, uint16(101), uint16(100)));
        router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, 0,
            user, block.timestamp + 1, FrontendFee({bps: 101, recipient: feeRecipient})
        );
    }

    function test_swapWithFee_revertsZeroFeeRecipient() public {
        _prepare(1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(PropAMMRouter.ZeroAddress.selector);
        router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, 0,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: address(0)})
        );
    }

    // amountOutMin is net; grossMin > best quote (900e18) so the pre-pull check rejects
    // with the grossed-up minimum.
    function test_swapWithFee_revertsQuoteBelowGrossMin() public {
        _prepare(1_000e18, 900e18); // quote + delivered both 900e18
        uint256 netMin = 950e18;
        uint256 grossMin = Math.ceilDiv(netMin * 10_000, 10_000 - 50);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.QuoteBelowMinimum.selector, grossMin, uint256(900e18)));
        router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, netMin,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );
    }

    function test_swapWithFee_zeroFee_paysFullAndNoFeeEvent() public {
        _prepare(1_000e18, 1_000e18);
        vm.recordLogs();
        vm.prank(user);
        (uint256 amountOut,) = router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, 1_000e18,
            user, block.timestamp + 1, FrontendFee({bps: 0, recipient: feeRecipient})
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != PropAMMRouter.FrontendFeeCharged.selector,
                "FrontendFeeCharged must not fire at zero fee"
            );
        }
        assertEq(amountOut, 1_000e18);
        assertEq(tokenOut.balanceOf(user), 1_000e18);
        assertEq(tokenOut.balanceOf(feeRecipient), 0);
    }

    function test_swapWithFee_tinyAmountFloorsFeeToZero() public {
        // grossMin = ceilDiv(100 * 10_000, 9_950) = 101; deliver 101.
        _prepare(10, 101);
        vm.prank(user);
        (uint256 amountOut,) = router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 10, 100,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );
        assertEq(amountOut, 101); // fee = 101*50/10_000 = 0 (floored)
        assertEq(tokenOut.balanceOf(feeRecipient), 0);
    }

    function test_swapWithFee_revertsWhenPaused() public {
        vm.prank(owner);
        router.pause();
        _prepare(1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(); // PausableUpgradeable.EnforcedPause
        router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, 0,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );
    }

    function test_swapWithFee_revertsPastDeadline() public {
        _prepare(1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(PropAMMRouter.Expired.selector);
        router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1_000e18, 0,
            user, block.timestamp - 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );
    }

    function _afterFot(uint256 v) internal pure returns (uint256) {
        return v - v * 100 / 10_000; // 1% burn
    }

    function test_swapWithFee_feeOnTransferTokenOut() public {
        MockFeeOnTransferERC20 fotOut = new MockFeeOnTransferERC20("FOT", "FOT", 100); // 1%
        uint256 routerOut = 1_000e18;
        tokenIn.mint(user, 1_000e18);
        fotOut.mint(address(swapRouter), routerOut);
        swapRouter.setAmountOut(routerOut);
        quoter.setQuote(routerOut);
        vm.prank(user);
        tokenIn.approve(address(router), 1_000e18);

        // Mock transfers routerOut to the router, burning 1% on the way in.
        uint256 delivered = _afterFot(routerOut);
        uint256 fee = delivered * 50 / 10_000;
        uint256 net = delivered - fee;

        vm.prank(user);
        (uint256 amountOut,) = router.swapWithFeeV1(
            address(tokenIn), address(fotOut), 1_000e18, 0,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, net);
        // Each outbound leg burns another 1%.
        assertEq(fotOut.balanceOf(feeRecipient), _afterFot(fee));
        assertEq(fotOut.balanceOf(user), _afterFot(net));
        assertEq(fotOut.balanceOf(address(router)), 0);
    }

    // For any feeBps in [0, MAX_FEE_BPS] and any delivered >= grossMin, the user nets
    // at least amountOutMin, the fee is the floored bps, and nothing is stranded.
    function testFuzz_swapWithFee_netNeverBelowMin(uint16 rawBps, uint256 netMin, uint256 delivered) public {
        uint16 bps = uint16(bound(rawBps, 0, 100));
        netMin = bound(netMin, 0, 1e27);
        uint256 grossMin = Math.ceilDiv(netMin * 10_000, 10_000 - bps);
        delivered = bound(delivered, grossMin == 0 ? 1 : grossMin, 1e30);

        _prepare(1e18, delivered);

        vm.prank(user);
        (uint256 amountOut,) = router.swapWithFeeV1(
            address(tokenIn), address(tokenOut), 1e18, netMin,
            user, block.timestamp + 1, FrontendFee({bps: bps, recipient: feeRecipient})
        );

        uint256 expectedFee = delivered * bps / 10_000;
        assertEq(amountOut, delivered - expectedFee);
        assertGe(amountOut, netMin); // the core guarantee
        assertEq(tokenOut.balanceOf(feeRecipient), expectedFee);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    function test_swapViaVenueWithFee_bebopCustodyPath() public {
        // Place mock Bebop code at the hard-coded BEBOP_ROUTER address.
        vm.etch(BEBOP_ROUTER, address(new MockBebop()).code);

        uint256 delivered = 1_000e18;
        tokenIn.mint(user, 1_000e18);
        tokenOut.mint(BEBOP_ROUTER, delivered); // Bebop delivers this to the router
        vm.prank(user);
        tokenIn.approve(address(router), 1_000e18);

        uint256 fee = delivered * 50 / 10_000;
        uint256 net = delivered - fee;

        vm.prank(user);
        uint256 amountOut = router.swapViaVenueWithFeeV1(
            BEBOP_ROUTER, address(tokenIn), address(tokenOut), 1_000e18, net,
            user, block.timestamp + 1, FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, net);
        assertEq(tokenOut.balanceOf(user), net);
        assertEq(tokenOut.balanceOf(feeRecipient), fee);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    // Characterization: existing fee-free swapV1 routes through the fallback and
    // emits Swapped(recipient = user, amountOut = delivered). Guards Task 2.
    function test_swapV1_fallback_emitsSwapped() public {
        _prepare(1_000e18, 990e18);

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.Swapped(
            user, address(tokenIn), address(tokenOut), 1_000e18, 990e18, user, address(swapRouter)
        );

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), 1_000e18, 990e18, user, block.timestamp + 1);

        assertEq(amountOut, 990e18);
        assertEq(executedVenue, address(swapRouter));
        assertEq(tokenOut.balanceOf(user), 990e18);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }
}
