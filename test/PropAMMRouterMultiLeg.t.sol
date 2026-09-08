// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {ETH_SENTINEL, WETH} from "../src/libraries/Constants.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockLinearSwapRouter, MockLinearQuoterV2} from "./mocks/MockLinearUniswap.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {FrontendFees} from "../src/libraries/FrontendFees.sol";
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

    //--------------------------------------------------//
    // Coalesced-fallback floor (finding: unfloored slice) //
    //--------------------------------------------------//

    /// @dev THE regression for the unfloored-fallback hole. venueA is priced
    /// 2:1 (better than Uniswap's 1:1) and clears the aggregate `amountOutMin`
    /// on its own; venueB reverts, so its 100e18 falls into the coalesced
    /// Uniswap swap. Before the fix the shortfall term collapsed to zero and
    /// that swap went out with `amountOutMinimum = 0`. `fallbackMinOut` is the
    /// caller's lever and must floor it.
    function test_swapMultiLeg_fallbackMinOutFloorsCoalescedSwapWhenShortfallIsZero() public {
        _fundUser(300e18);
        venueB.setActive(false); // hard revert -> leg coalesces into Uniswap

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 200e18, 400e18); // delivers 400e18
        legs[1] = _leg(address(venueB), 100e18, 0); // fails -> 100e18 to Uniswap

        // venueA alone (400e18) clears the aggregate min, so the shortfall
        // term is zero. Uniswap pays 1:1, so the honest 100e18 slice yields
        // 100e18. `fallbackMinOut` is priced for the FULL 300e18 input and
        // pro-rated by fbAmount/totalIn = 100/300, so 300e18 becomes exactly
        // a 100e18 floor; nudging it up must revert rather than silently
        // execute unprotected.
        vm.prank(user);
        vm.expectRevert(); // MockLinearSwapRouter's own "uni-slippage"
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, 300e18 + 3, user, block.timestamp + 1);

        // At exactly the honest output it goes through.
        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, 300e18, user, block.timestamp + 1);
        assertEq(amountOut, 500e18, "400 from venueA + 100 from the coalesced Uniswap swap");
    }

    /// @dev Proves the shortfall term really is zero in the scenario above, so
    /// the previous test is testing `fallbackMinOut` and not the aggregate min.
    /// With `fallbackMinOut = 0` the coalesced swap is unfloored: a Uniswap
    /// that pays almost nothing still succeeds, because venueA covers the
    /// aggregate on its own. This is the documented residual exposure of
    /// passing zero, pinned so a future change to the shortfall term is
    /// visible rather than silent.
    function test_swapMultiLeg_zeroFallbackMinOutLeavesSliceUnfloored() public {
        _fundUser(300e18);
        venueB.setActive(false);
        uni.setPrice(1000, 1); // Uniswap now pays 1/1000 -> 0.1e18 for 100e18

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 200e18, 400e18);
        legs[1] = _leg(address(venueB), 100e18, 0);

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, 0, user, block.timestamp + 1);
        assertEq(amountOut, 400e18 + 0.1e18, "unfloored slice executed at the terrible rate");
    }

    /// @dev The explicit fallback leg's floor IS diluted when a failed prop
    /// leg merges into the same swap, and that is deliberate. An explicit leg
    /// of 100e18 with `minOut = 95e18` states a rate of 0.95; venueB then
    /// fails, adding 100e18 to the same swap. The floor stays 95e18 over
    /// 200e18 of input — an effective rate of 0.475 — so a Uniswap paying
    /// only 0.50 still clears it.
    ///
    /// Scaling the floor to 190e18 to "undo" the dilution is UNSOUND: `minOut`
    /// is a rate priced at the explicit leg's size, and Uniswap's unit rate
    /// falls with size (see
    /// `test_split_scaledExplicitFloorWouldRevertHonestSwaps`). `fallbackMinOut`
    /// is the term that actually covers the merged portion, asserted below.
    function test_swapMultiLeg_explicitFallbackMinIsDilutedByFailedPropLeg() public {
        _fundUser(300e18);
        venueB.setActive(false);
        uni.setPrice(100, 50); // Uniswap pays 0.50 — below the stated 0.95

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](3);
        legs[0] = _leg(address(venueA), 100e18, 200e18); // clears the aggregate alone
        legs[1] = _leg(address(router.fallbackSwapRouter()), 100e18, 95e18); // rate 0.95
        legs[2] = _leg(address(venueB), 100e18, 0); // fails -> merges in

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 200e18, 0, user, block.timestamp + 1);
        assertEq(amountOut, 200e18 + 100e18, "diluted floor (95e18 over 200e18 in) was met by 0.50");

        // `fallbackMinOut` is the remedy: 285e18 is 0.95 over the full 300e18
        // input, which pro-rates to 190e18 on the 200e18 merged slice — the
        // rate the caller actually wanted — and the swap must revert.
        _fundUser(300e18);
        vm.prank(user);
        vm.expectRevert();
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 200e18, 285e18, user, block.timestamp + 1);
    }

    /// @dev A failed PROP leg's own `minOut` still must NOT be carried into the
    /// coalesced floor: it was priced off a better venue, so inheriting it
    /// would revert the fallback exactly when it is needed to recover the leg.
    function test_swapMultiLeg_failedPropLegMinOutNotInheritedByFallback() public {
        _fundUser(200e18);
        venueB.setActive(false);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 200e18);
        // venueB's leg demands 200e18 at its 2:1 rate. Uniswap pays 1:1, so
        // inheriting that floor would make the recovery swap impossible.
        legs[1] = _leg(address(venueB), 100e18, 200e18);

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
        assertEq(amountOut, 200e18 + 100e18, "fallback recovered the leg at Uniswap's rate");
    }

    /// @dev `swapMultiLegWithFeeV1` treats both AGGREGATE minimums as
    /// net-of-fee, so `fallbackMinOut` is grossed up like `amountOutMin` and
    /// then pro-rated. Full-order basis: 300e18 net grosses to ~301.507e18 and
    /// pro-rates by 100/300 to ~100.502e18 on the slice, which a 1:1 Uniswap
    /// over 100e18 in cannot meet -> revert. 297e18 net grosses to
    /// ~298.492e18 and pro-rates to ~99.497e18, which it can.
    function test_swapMultiLegWithFee_fallbackMinOutIsNetBasis() public {
        _fundUser(600e18);
        venueB.setActive(false);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 200e18, 400e18);
        legs[1] = _leg(address(venueB), 100e18, 0);

        vm.prank(user);
        vm.expectRevert();
        router.swapMultiLegWithFeeV1(
            legs,
            address(tokenIn),
            address(tokenOut),
            0,
            300e18,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        vm.prank(user);
        router.swapMultiLegWithFeeV1(
            legs,
            address(tokenIn),
            address(tokenOut),
            0,
            297e18,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );
    }

    function test_swapMultiLeg_twoLegs_deliversSumToRecipient() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 200e18);
        legs[1] = _leg(address(venueB), 200e18, 400e18);

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 600e18, 0, user, block.timestamp + 1);

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
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_aggregateMinEnforced() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueB), 200e18, 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 601e18, 600e18));
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 601e18, 0, user, block.timestamp + 1);
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
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 300e18, 0, user, block.timestamp + 1);

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
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, 0, user, block.timestamp + 1);

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
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 150e18, 0, user, block.timestamp + 1);
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
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 100e18, 0, user, block.timestamp + 1);

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
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
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
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnZeroLegs() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidLegCount.selector, 0));
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnTooManyLegs() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](9);
        for (uint256 i = 0; i < 9; i++) {
            legs[i] = _leg(address(venueA), 1e18, 0);
        }
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidLegCount.selector, 9));
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnUnknownVenue() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(makeAddr("notAVenue"), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(UnknownVenue.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnZeroLegAmount() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 0, 0);
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_revertsOnStrayMsgValueForERC20() public {
        _fundUser(1e18);
        vm.deal(user, 1 ether);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, 0, 1 ether));
        router.swapMultiLegV1{value: 1 ether}(
            legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1
        );
    }

    function test_swapMultiLeg_revertsPastDeadline() public {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(Expired.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp - 1);
    }

    function test_swapMultiLeg_revertsWhenPaused() public {
        _fundUser(1e18);
        vm.prank(owner);
        router.pause();
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_duplicateVenuesAllowed() public {
        _fundUser(200e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueA), 100e18, 0);
        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 400e18, 0, user, block.timestamp + 1);
        assertEq(amountOut, 400e18);
    }

    function _etchWETH() internal {
        // Place a WETH implementation at the hardcoded mainnet address. Etch
        // copies code only (storage starts empty), and the etched contract
        // needs ETH to honor withdraw() for balances minted via deposit().
        MockWETH impl = new MockWETH();
        vm.etch(WETH, address(impl).code);
        vm.deal(WETH, 100 ether);
    }

    function test_swapMultiLeg_ethIn_wrapsOnceAndSplits() public {
        _etchWETH();
        vm.deal(user, 3 ether);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 1 ether, 0);
        legs[1] = _leg(address(venueB), 2 ether, 0);

        vm.prank(user);
        uint256 amountOut = router.swapMultiLegV1{value: 3 ether}(
            legs, ETH_SENTINEL, address(tokenOut), 6 ether, 0, user, block.timestamp + 1
        );
        assertEq(amountOut, 6 ether);
        assertEq(tokenOut.balanceOf(user), 6 ether);
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router retained WETH");
    }

    function test_swapMultiLeg_ethIn_wrongValueReverts() public {
        _etchWETH();
        vm.deal(user, 3 ether);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = _leg(address(venueA), 2 ether, 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, 2 ether, 1 ether));
        router.swapMultiLegV1{value: 1 ether}(legs, ETH_SENTINEL, address(tokenOut), 0, 0, user, block.timestamp + 1);
    }

    function test_swapMultiLeg_ethOut_unwrapsAggregateOnce() public {
        _etchWETH();
        // Venues deliver WETH: fund them at the etched WETH address.
        vm.deal(address(this), 10 ether);
        IWETH(WETH).deposit{value: 10 ether}();
        IERC20(WETH).transfer(address(venueA), 6 ether);
        IERC20(WETH).transfer(address(venueB), 4 ether);
        venueA.setPrice(1, 2); // in tokenIn -> out WETH at x2
        venueB.setPrice(1, 2);
        _fundUser(3e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 1e18, 0);
        legs[1] = _leg(address(venueB), 2e18, 0);

        uint256 balBefore = user.balance;
        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), ETH_SENTINEL, 6e18, 0, user, block.timestamp + 1);
        assertEq(amountOut, 6e18);
        assertEq(user.balance - balBefore, 6e18); // raw ETH received
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router retained WETH");
    }

    function test_swapMultiLegWithFee_skimsAggregate() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueB), 200e18, 0);

        uint256 gross = 600e18;
        uint256 fee = gross * 50 / 10_000; // 3e18
        uint256 net = gross - fee;

        vm.prank(user);
        uint256 amountOut = router.swapMultiLegWithFeeV1(
            legs,
            address(tokenIn),
            address(tokenOut),
            net,
            0,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, net);
        assertEq(tokenOut.balanceOf(user), net);
        assertEq(tokenOut.balanceOf(feeRecipient), fee);
        assertEq(tokenOut.balanceOf(address(router)), 0, "router retained tokenOut");
    }

    function test_swapMultiLegWithFee_netMinGrossedUp() public {
        _fundUser(300e18);
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 100e18, 0);
        legs[1] = _leg(address(venueB), 200e18, 0);

        // Gross delivery is 600e18; demanding a net of 600e18 at 50bps needs
        // gross ~603e18 -> must revert InsufficientOutput on the grossed min.
        uint256 grossMin = FrontendFees._grossUp(600e18, 50);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, grossMin, 600e18));
        router.swapMultiLegWithFeeV1(
            legs,
            address(tokenIn),
            address(tokenOut),
            600e18,
            0,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );
    }

    function test_swapMultiLegWithFee_ethOut_skimsAndForwardsRawETH() public {
        // Same wiring as test_swapMultiLeg_ethOut_unwrapsAggregateOnce, but with
        // a frontend fee: `_executeLegs` unwraps the aggregate WETH to raw ETH
        // held by the router (recipient == address(this) internally), then
        // `_skimAndDisburse` must notice tokenOut == ETH_SENTINEL and push raw
        // ETH to both the fee recipient and the user, leaving nothing behind.
        _etchWETH();
        vm.deal(address(this), 10 ether);
        IWETH(WETH).deposit{value: 10 ether}();
        IERC20(WETH).transfer(address(venueA), 6 ether);
        IERC20(WETH).transfer(address(venueB), 4 ether);
        venueA.setPrice(1, 2); // in tokenIn -> out WETH at x2
        venueB.setPrice(1, 2);
        _fundUser(3e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 1e18, 0);
        legs[1] = _leg(address(venueB), 2e18, 0);

        uint256 gross = 6e18; // 1e18*2 + 2e18*2
        uint256 fee = gross * 50 / 10_000;
        uint256 net = gross - fee;

        uint256 userBalBefore = user.balance;
        uint256 feeRecipientBalBefore = feeRecipient.balance;

        vm.prank(user);
        uint256 amountOut = router.swapMultiLegWithFeeV1(
            legs,
            address(tokenIn),
            ETH_SENTINEL,
            net,
            0,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, net);
        assertEq(user.balance - userBalBefore, net, "user did not receive net raw ETH");
        assertEq(feeRecipient.balance - feeRecipientBalBefore, fee, "fee recipient did not receive raw ETH fee");
        assertEq(address(router).balance, 0, "router retained ETH");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router retained WETH");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_swapMultiLeg_conservesInputAndMeetsMin(uint96 rawA, uint96 rawB, bool failA) public {
        // Bounded to 100_000e18 (not the brief's 1_000_000e18): at venueA/B's
        // x2 price a maximal leg would demand a 2_000_000e18 payout, but
        // `setUp` only funds each venue with 1_000_000e18, so the venue's
        // transfer would revert for reasons unrelated to the invariant here.
        uint256 amtA = bound(uint256(rawA), 1, 100_000e18);
        uint256 amtB = bound(uint256(rawB), 1, 100_000e18);
        if (failA) venueA.setActive(false);
        uni.setPrice(1, 1);
        _fundUser(amtA + amtB);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), amtA, 0);
        legs[1] = _leg(address(venueB), amtB, 0);

        // Expected: legB always x2; legA x2 when healthy, 1:1 via uniswap when failed.
        uint256 expected = amtB * 2 + (failA ? amtA : amtA * 2);

        vm.prank(user);
        uint256 amountOut =
            router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), expected, 0, user, block.timestamp + 1);

        assertEq(amountOut, expected);
        assertEq(tokenIn.balanceOf(user), 0);
        assertEq(tokenIn.balanceOf(address(router)), 0); // input fully routed
        assertEq(tokenOut.balanceOf(user), expected);
    }

    //--------------------------------------//
    // Event attribution (review finding)   //
    //--------------------------------------//

    /// @dev keccak256("Swapped(address,address,address,uint256,uint256,address,address)")
    function _swappedTopic() internal pure returns (bytes32) {
        return keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
    }

    function test_swapMultiLegWithFee_swappedEventsNameTheRealRecipient() public {
        // The fee variants route legs to the ROUTER so the fee can be skimmed
        // from the aggregate before forwarding. That is an execution detail:
        // the `Swapped` events must still name the user, or every indexer
        // attributing volume by `recipient` books these swaps to the router.
        _fundUser(100e18);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = _leg(address(venueA), 60e18, 0);
        legs[1] = _leg(address(venueB), 40e18, 0);

        vm.recordLogs();
        vm.prank(user);
        router.swapMultiLegWithFeeV1(
            legs,
            address(tokenIn),
            address(tokenOut),
            0,
            0,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(router) || logs[i].topics[0] != _swappedTopic()) continue;
            (,, address recipient,) = abi.decode(logs[i].data, (uint256, uint256, address, address));
            assertEq(recipient, user, "Swapped.recipient must be the user, not the router");
            seen++;
        }
        assertEq(seen, 2, "one Swapped per executed leg");
    }
}
