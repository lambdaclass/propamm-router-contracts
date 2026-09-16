// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter02} from "./mocks/MockSwapRouter02.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
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

    /// @dev Venue caps at 400 of a 1000 order. The probe finds 400 is quotable
    /// (full 1000 reverts, half 500 reverts, so the downward search in Task 6
    /// is NOT exercised here — instead cap the venue at exactly the half point).
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
    function test_split_deadVenueIsSkipped() public {
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(0); // reverts at every size
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
    }

    /// @dev A venue quoting zero is not a candidate.
    function test_split_zeroQuoteVenueIsSkipped() public {
        MockCappedPropAMM venue = new MockCappedPropAMM();
        venue.setCap(type(uint256).max);
        venue.setRateBps(0); // quotes 0
        router.addVenue(address(venue));

        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
        assertEq(out, 990e18);
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
