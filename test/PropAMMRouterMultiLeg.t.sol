// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
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
}
