// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter, FrontendFee} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";

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
