// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMFeeWrapper} from "../src/PropAMMFeeWrapper.sol";
import {PropAMMFeeWrapperV2} from "./mocks/PropAMMFeeWrapperV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockPropAMMRouter} from "./mocks/MockPropAMMRouter.sol";

contract PropAMMFeeWrapperTest is Test {
    PropAMMFeeWrapper wrapper;
    MockPropAMMRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address user = makeAddr("user");
    uint16 constant FEE_BPS = 50; // 0.5%

    function _deploy(uint16 feeBps_) internal returns (PropAMMFeeWrapper) {
        PropAMMFeeWrapper impl = new PropAMMFeeWrapper();
        bytes memory data = abi.encodeCall(
            PropAMMFeeWrapper.initialize, (address(router), feeRecipient, feeBps_, owner)
        );
        return PropAMMFeeWrapper(address(new ERC1967Proxy(address(impl), data)));
    }

    function setUp() public {
        router = new MockPropAMMRouter();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        wrapper = _deploy(FEE_BPS);
    }

    function test_initialize_setsState() public view {
        assertEq(wrapper.router(), address(router));
        assertEq(wrapper.feeRecipient(), feeRecipient);
        assertEq(wrapper.feeBps(), FEE_BPS);
        assertEq(wrapper.owner(), owner);
    }

    function test_initialize_revertsOnZeroRouter() public {
        PropAMMFeeWrapper impl = new PropAMMFeeWrapper();
        bytes memory data = abi.encodeCall(
            PropAMMFeeWrapper.initialize, (address(0), feeRecipient, FEE_BPS, owner)
        );
        vm.expectRevert(PropAMMFeeWrapper.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_initialize_revertsOnFeeTooHigh() public {
        PropAMMFeeWrapper impl = new PropAMMFeeWrapper();
        bytes memory data = abi.encodeCall(
            PropAMMFeeWrapper.initialize, (address(router), feeRecipient, 101, owner)
        );
        vm.expectRevert(abi.encodeWithSelector(PropAMMFeeWrapper.FeeBpsTooHigh.selector, uint16(101), uint16(100)));
        new ERC1967Proxy(address(impl), data);
    }

    function test_setFeeBps_ownerWithinCap() public {
        vm.prank(owner);
        wrapper.setFeeBps(100);
        assertEq(wrapper.feeBps(), 100);
    }

    function test_setFeeBps_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PropAMMFeeWrapper.FeeBpsTooHigh.selector, uint16(101), uint16(100)));
        wrapper.setFeeBps(101);
    }

    function test_setFeeBps_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        wrapper.setFeeBps(10);
    }

    function test_setFeeRecipient_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(PropAMMFeeWrapper.ZeroAddress.selector);
        wrapper.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_revertsOnSelf() public {
        vm.prank(owner);
        vm.expectRevert(PropAMMFeeWrapper.ZeroAddress.selector);
        wrapper.setFeeRecipient(address(wrapper));
    }

    // Funds the user, the router (with tokenOut to deliver), and approves the wrapper.
    function _prepareSwap(uint256 amountIn, uint256 routerOut) internal {
        tokenIn.mint(user, amountIn);
        tokenOut.mint(address(router), routerOut);
        router.setAmountOut(routerOut);
        vm.prank(user);
        tokenIn.approve(address(wrapper), amountIn);
    }

    function _swap(uint256 amountIn, uint256 amountOutMin) internal returns (uint256) {
        vm.prank(user);
        return wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut),
            amountIn, amountOutMin, user, uint24(3000), block.timestamp + 1
        );
    }

    function test_swap_takesFeeAndPaysUser() public {
        _prepareSwap(1_000e18, 1_000e18);
        uint256 expectedFee = 1_000e18 * uint256(FEE_BPS) / 10_000; // 5e18
        uint256 expectedUser = 1_000e18 - expectedFee;

        uint256 got = _swap(1_000e18, expectedUser);

        assertEq(got, expectedUser);
        assertEq(tokenOut.balanceOf(user), expectedUser);
        assertEq(tokenOut.balanceOf(feeRecipient), expectedFee);
        assertEq(tokenIn.balanceOf(address(wrapper)), 0);
        assertEq(tokenOut.balanceOf(address(wrapper)), 0);
    }

    function test_swap_zeroFeeEmitsSwapButNoFeeCollected() public {
        wrapper = _deploy(0);
        _prepareSwap(1_000e18, 1_000e18);

        vm.recordLogs();
        uint256 got = _swap(1_000e18, 1_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawSwapExecuted;
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != PropAMMFeeWrapper.FeeCollected.selector,
                "FeeCollected must not fire at zero fee"
            );
            if (logs[i].topics[0] == PropAMMFeeWrapper.SwapExecuted.selector) {
                sawSwapExecuted = true;
            }
        }
        assertTrue(sawSwapExecuted, "SwapExecuted must fire");

        assertEq(got, 1_000e18);
        assertEq(tokenOut.balanceOf(feeRecipient), 0);
        assertEq(tokenOut.balanceOf(user), 1_000e18);
    }

    function test_swap_tinyAmountFloorsFeeToZero() public {
        // grossMin = ceilDiv(100 * 10_000, 9_950) = 101; router delivers 101.
        // fee = 101 * 50 / 10_000 = 0 (floors), user gets 101.
        _prepareSwap(10, 101); // routerOut=101 satisfies grossMin=101
        uint256 got = _swap(10, 100);
        assertEq(got, 101);
        assertEq(tokenOut.balanceOf(feeRecipient), 0);
    }

    function test_swap_passesCeilDerivedGrossMin() public {
        _prepareSwap(1_000e18, 1_000e18);
        uint256 amountOutMin = 900e18;
        _swap(1_000e18, amountOutMin);
        uint256 expectedGrossMin = Math.ceilDiv(amountOutMin * 10_000, 10_000 - FEE_BPS);
        assertEq(router.lastAmountOutMin(), expectedGrossMin);
        assertEq(router.lastRecipient(), address(wrapper));
    }

    function test_swap_revertsIdenticalTokens() public {
        tokenIn.mint(user, 1e18);
        vm.prank(user);
        tokenIn.approve(address(wrapper), 1e18);
        vm.prank(user);
        vm.expectRevert(PropAMMFeeWrapper.IdenticalTokens.selector);
        wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenIn),
            1e18, 0, user, uint24(3000), block.timestamp + 1
        );
    }

    function test_swap_revertsWhenRouterCannotMeetGrossMin() public {
        _prepareSwap(1_000e18, 800e18); // router returns 800, below grossMin for 900 min
        vm.prank(user);
        vm.expectRevert(MockPropAMMRouter.MockInsufficientOutput.selector);
        wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut),
            1_000e18, 900e18, user, uint24(3000), block.timestamp + 1
        );
    }

    function test_swap_revertsWhenRouterReverts() public {
        _prepareSwap(1_000e18, 1_000e18);
        router.setShouldRevert(true);
        vm.prank(user);
        vm.expectRevert(MockPropAMMRouter.MockForcedRevert.selector);
        wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut),
            1_000e18, 0, user, uint24(3000), block.timestamp + 1
        );
        assertEq(tokenIn.balanceOf(user), 1_000e18); // rolled back
    }

    function test_swap_revertsPastDeadline() public {
        _prepareSwap(1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(MockPropAMMRouter.Expired.selector);
        wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut),
            1_000e18, 0, user, uint24(3000), block.timestamp - 1
        );
    }

    function test_swap_revertsWhenPaused() public {
        vm.prank(owner);
        wrapper.pause();
        _prepareSwap(1_000e18, 1_000e18);
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut),
            1_000e18, 0, user, uint24(3000), block.timestamp + 1
        );
    }

    // FoT burn applied by MockFeeOnTransferERC20 (1% = 100 bps), matching its formula exactly.
    function _afterFot(uint256 v) internal pure returns (uint256) {
        return v - v * 100 / 10_000;
    }

    function test_swap_feeOnTransferTokenOutUsesMeasuredDelivered() public {
        MockFeeOnTransferERC20 fotOut = new MockFeeOnTransferERC20("FOT", "FOT", 100); // 1% burn on transfer
        uint256 routerOut = 1_000e18;
        tokenIn.mint(user, 1_000e18);
        fotOut.mint(address(router), routerOut);
        router.setAmountOut(routerOut);
        vm.prank(user);
        tokenIn.approve(address(wrapper), 1_000e18);

        uint256 delivered = _afterFot(routerOut);          // wrapper's measured receipt
        uint256 fee = delivered * FEE_BPS / 10_000;
        uint256 userAmount = delivered - fee;

        vm.prank(user);
        uint256 got = wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(fotOut),
            1_000e18, 0, user, uint24(3000), block.timestamp + 1
        );

        assertEq(got, userAmount);
        assertEq(fotOut.balanceOf(feeRecipient), _afterFot(fee));
        assertEq(fotOut.balanceOf(user), _afterFot(userAmount));
        assertEq(fotOut.balanceOf(address(wrapper)), 0);
    }

    function test_quote_subtractsFee() public {
        router.setQuote(1_000e18, IPropAMMRouter.Venue.Bebop);
        (uint256 net, IPropAMMRouter.Venue v) = wrapper.quote(address(tokenIn), address(tokenOut), 1e18, uint24(3000));
        assertEq(net, 1_000e18 - (1_000e18 * uint256(FEE_BPS) / 10_000));
        assertEq(uint8(v), uint8(IPropAMMRouter.Venue.Bebop));
    }

    function test_quote_defaultFeeOverload() public {
        router.setQuote(2_000e18, IPropAMMRouter.Venue.Kipseli);
        (uint256 net,) = wrapper.quote(address(tokenIn), address(tokenOut), 1e18);
        assertEq(net, 2_000e18 - (2_000e18 * uint256(FEE_BPS) / 10_000));
    }

    function test_quoteVenue_subtractsFee() public {
        router.setQuote(500e18, IPropAMMRouter.Venue.FermiSwap);
        uint256 net = wrapper.quoteVenue(IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut), 1e18, uint24(3000));
        assertEq(net, 500e18 - (500e18 * uint256(FEE_BPS) / 10_000));
    }

    function test_quoteVenue_defaultFeeOverload() public {
        router.setQuote(500e18, IPropAMMRouter.Venue.FermiSwap);
        uint256 net = wrapper.quoteVenue(IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut), 1e18);
        assertEq(net, 500e18 - (500e18 * uint256(FEE_BPS) / 10_000));
    }

    function testFuzz_userReceivesGrossMinusFee(uint16 rawFee, uint256 gross) public {
        uint16 fee = uint16(bound(rawFee, 0, 100));
        gross = bound(gross, 1, 1e30);
        wrapper = _deploy(fee);

        tokenIn.mint(user, 1e18);
        tokenOut.mint(address(router), gross);
        router.setAmountOut(gross);
        vm.prank(user);
        tokenIn.approve(address(wrapper), 1e18);

        uint256 expectedFee = gross * uint256(fee) / 10_000;
        uint256 expectedUser = gross - expectedFee;

        // amountOutMin = 0 so the grossMin/ceil interaction can't cause a 1-wei
        // false revert at the boundary; the payout *math* is what this fuzzes.
        vm.prank(user);
        uint256 got = wrapper.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tokenIn), address(tokenOut),
            1e18, 0, user, uint24(3000), block.timestamp + 1
        );
        assertEq(got, expectedUser);
        assertEq(tokenOut.balanceOf(feeRecipient), expectedFee);
        assertEq(tokenOut.balanceOf(user), expectedUser);
    }

    function test_allowanceZeroedAfterSwap() public {
        _prepareSwap(1_000e18, 1_000e18);
        _swap(1_000e18, 0);
        assertEq(tokenIn.allowance(address(wrapper), address(router)), 0);
    }

    function test_upgrade_ownerOnlyAndPreservesStorage() public {
        PropAMMFeeWrapperV2 v2 = new PropAMMFeeWrapperV2();

        // non-owner cannot upgrade
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        wrapper.upgradeToAndCall(address(v2), "");

        // owner upgrades; storage preserved
        vm.prank(owner);
        wrapper.upgradeToAndCall(address(v2), "");
        assertEq(PropAMMFeeWrapperV2(address(wrapper)).version(), 2);
        assertEq(wrapper.feeBps(), FEE_BPS);
        assertEq(wrapper.feeRecipient(), feeRecipient);
        assertEq(wrapper.router(), address(router));
    }
}
