// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockLinearSwapRouter, MockLinearQuoterV2} from "./mocks/MockLinearUniswap.sol";
import "../src/libraries/Errors.sol";

contract PropAMMRouterMultiLegTest is Test {
    PropAMMRouter router;
    AccessManager manager;
    MockLinearSwapRouter uni;
    MockLinearQuoterV2 quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockCappedPropAMM venueA; // out = in * 2
    MockCappedPropAMM venueB; // out = in * 2

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

        venueA = new MockCappedPropAMM(1, 2);
        venueB = new MockCappedPropAMM(1, 2);
        tokenOut.mint(address(venueA), 1_000_000e18);
        tokenOut.mint(address(venueB), 1_000_000e18);
        vm.startPrank(owner);
        router.addVenue(address(venueA));
        router.addVenue(address(venueB));
        vm.stopPrank();
    }

    function _fundUser(uint256 amount) internal {
        tokenIn.mint(user, amount);
        vm.prank(user);
        tokenIn.approve(address(router), amount);
    }

    function _leg(address venue, uint256 amountIn, uint256 minOut) internal pure returns (IPropAMMRouter.Leg memory) {
        return IPropAMMRouter.Leg({venue: venue, amountIn: amountIn, minOut: minOut});
    }

    function test_swapMultiLeg_twoLegs_deliversSumToRecipient() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 200e18);
        legs[1] = _leg(address(venueB), 200e18, 400e18);

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 600e18, user, block.timestamp + 1);

        assertEq(amountOut, 600e18);
        assertEq(tokenOut.balanceOf(user), 600e18);
        assertEq(tokenIn.balanceOf(user), 0);
        // Push-payment: each venue consumed its leg's input.
        assertEq(tokenIn.balanceOf(address(venueA)), 100e18);
        assertEq(tokenIn.balanceOf(address(venueB)), 200e18);
        assertEq(tokenIn.balanceOf(address(router)), 0);
    }

    function test_swapMultiLeg_emitsSwappedPerLeg() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueB), 200e18, 0);

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.Swapped(user, address(tokenIn), address(tokenOut), 100e18, 200e18, user, address(venueA));
        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.Swapped(user, address(tokenIn), address(tokenOut), 200e18, 400e18, user, address(venueB));
        vm.prank(user);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_aggregateMinEnforced() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueB), 200e18, 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 601e18, 600e18));
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 601e18, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_failedLegsCoalesceIntoOneUniswapSwap() public {
        // Both prop legs revert (inactive) -> ONE uniswap swap for the total.
        venueA.setActive(false);
        venueB.setActive(false);
        uni.setPrice(1, 1); // uni pays 1:1
        _fundUser(300e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueB), 200e18, 0);

        vm.expectEmit(true, true, true, true, address(router));
        emit IPropAMMRouter.Swapped(user, address(tokenIn), address(tokenOut), 300e18, 300e18, user, address(uni));
        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 300e18, user, block.timestamp + 1);

        assertEq(amountOut, 300e18);
        assertEq(tokenOut.balanceOf(user), 300e18);
        assertEq(tokenIn.balanceOf(address(uni)), 300e18); // one pull of the coalesced total
    }

    function test_swapMultiLeg_explicitFallbackLegJoinsCoalescedSwap() public {
        uni.setPrice(1, 1);
        _fundUser(300e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 200e18);
        legs[1] = _leg(address(uni), 200e18, 200e18); // explicit uniswap leg

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, user, block.timestamp + 1);

        // venueA: 100 -> 200; uni: 200 -> 200.
        assertEq(amountOut, 400e18);
    }

    function test_swapMultiLeg_shortfallMinIsSaturating() public {
        // Prop leg over-delivers past the aggregate min while a fallback leg
        // remains: the coalesced uniswap min must clamp to 0, not underflow.
        uni.setPrice(1, 1);
        _fundUser(200e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0); // delivers 200e18
        legs[1] = _leg(address(uni), 100e18, 0); // delivers 100e18

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 150e18, user, block.timestamp + 1);
        // 150e18 min already exceeded by leg 0 alone (200e18): no revert, both legs run.
        assertEq(amountOut, 300e18);
    }

    function test_swapMultiLeg_underDeliveryTripsPerLegMinAndFallsBack() public {
        // venueA quotes x2 but delivers 10% short and ignores minOut checks
        // itself; the ROUTER's per-leg min must catch it and reroute the leg.
        venueA.setHonorMinOut(false);
        venueA.setShortChangeBps(1_000);
        uni.setPrice(1, 1);
        _fundUser(100e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 100e18, 200e18); // real floor

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 100e18, user, block.timestamp + 1);

        // Leg failed the 200e18 floor (delivered would be 180e18) -> rolled
        // back -> uniswap fallback filled 100 -> 100.
        assertEq(amountOut, 100e18);
        assertEq(tokenIn.balanceOf(address(venueA)), 0); // push transfer rolled back
    }

    function test_swapMultiLeg_zeroMinLegAcceptsUnderDelivery() public {
        // Same short-changing venue, but minOut = 0: the leg "succeeds" short
        // and only the aggregate min protects.
        venueA.setHonorMinOut(false);
        venueA.setShortChangeBps(1_000);
        _fundUser(100e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 100e18, 0);

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
        assertEq(amountOut, 180e18); // 200e18 quote minus 10% short-change
    }

    function test_swapMultiLeg_explicitFallbackLegMinOutHonored() public {
        // uni pays 1:2 (half), explicit uni leg demands more than it can pay.
        uni.setPrice(2, 1);
        _fundUser(100e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(uni), 100e18, 60e18); // uni will deliver 50e18 < 60e18

        vm.prank(user);
        vm.expectRevert(); // MockLinearSwapRouter's own "uni-slippage" require
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnZeroLegs() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidLegCount.selector, 0));
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnTooManyLegs() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](9);
        for (uint256 i = 0; i < 9; i++) {
            legs[i] = _leg(address(venueA), 1e18, 0);
        }
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidLegCount.selector, 9));
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnUnknownVenue() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(makeAddr("notAVenue"), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(UnknownVenue.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnZeroLegAmount() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 0, 0);
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnStrayMsgValueForERC20() public {
        _fundUser(1e18);
        vm.deal(user, 1 ether);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, 0, 1 ether));
        router.swapMultiLegV1{value: 1 ether}(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsPastDeadline() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(Expired.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp - 1);
    }

    function test_swapMultiLeg_revertsWhenPaused() public {
        _fundUser(1e18);
        vm.prank(owner);
        router.pause();
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_duplicateVenuesAllowed() public {
        _fundUser(200e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueA), 100e18, 0);
        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, user, block.timestamp + 1);
        assertEq(amountOut, 400e18);
    }
}
