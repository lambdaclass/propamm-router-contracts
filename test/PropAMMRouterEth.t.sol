// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {MockPropAMMExactOut} from "./mocks/MockPropAMMExactOut.sol";
import {ETH_SENTINEL, WETH} from "../src/libraries/Constants.sol";
import "../src/libraries/Errors.sol";

/// @title PropAMMRouterEthTest
/// @notice Exercises the native-ETH input paths through `_coreSwap`: ETH is
/// wrapped to WETH held by the router, so the venue path must `safeTransfer`
/// the router's WETH (payer == router) and the Uniswap fallback must NOT
/// re-pull. These six paths regressed repeatedly while moving to the
/// direct-pull model and an ERC-20-only suite never caught it.
/// @dev The router hard-codes the mainnet WETH address, so a `MockWETH` is
/// `vm.etch`ed there to make `IWETH(WETH).deposit` work off-fork.
contract PropAMMRouterEthTest is Test {
    PropAMMRouter internal router;
    AccessManager internal manager;
    MockV3SwapRouter internal fallbackRouter; // pulls tokenIn, so router ends clean
    MockQuoterV2 internal quoter;
    MockPropAMMExactOut internal venue; // 1:1 priced propAMM
    MockERC20 internal tokenOut;

    address internal owner = address(this);
    address internal recipient = makeAddr("recipient");

    // Whitelisted but code-less: its `swap` reverts, so `_dispatchVenue` rolls
    // back and the Uniswap fallback engages — used to drive the venue->fallback
    // path with an ETH input.
    address internal deadVenue = address(0xDEAD);

    uint256 internal constant AMOUNT_IN = 1 ether;

    function setUp() public {
        fallbackRouter = new MockV3SwapRouter();
        quoter = new MockQuoterV2();
        tokenOut = new MockERC20("TokenOut", "TOUT");

        // Put a working WETH at the address the router hard-codes.
        vm.etch(WETH, address(new MockWETH()).code);

        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(fallbackRouter), address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), initData))));

        // A 1:1 propAMM, funded with tokenOut liquidity to deliver.
        venue = new MockPropAMMExactOut(1, 1);
        tokenOut.mint(address(venue), 1_000 ether);
        router.addVenue(address(venue));
        router.addVenue(deadVenue);

        // Pre-fund + arm the fallback so it can deliver tokenOut when engaged.
        tokenOut.mint(address(fallbackRouter), 1_000 ether);
        fallbackRouter.setAmountOut(AMOUNT_IN);
        quoter.setQuote(AMOUNT_IN);

        vm.deal(address(this), 100 ether);
    }

    // --- ETH -> venue (happy path) ----------------------------------------

    function test_ethIn_venue_executes() public {
        (uint256 amountOut, address executedVenue) = router.swapViaVenueV1{value: AMOUNT_IN}(
            address(venue), ETH_SENTINEL, address(tokenOut), AMOUNT_IN, AMOUNT_IN, recipient, block.timestamp + 1
        );

        assertEq(executedVenue, address(venue), "should execute on the venue, not fall back");
        assertEq(amountOut, AMOUNT_IN, "1:1 venue should deliver amountIn");
        assertEq(tokenOut.balanceOf(recipient), AMOUNT_IN, "recipient tokenOut");
        // Router pushed all wrapped WETH to the venue; nothing left behind.
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH stranded in router");
        assertEq(address(router).balance, 0, "no ETH stranded in router");
    }

    // --- ETH -> Uniswap fallback (selected directly) ----------------------

    function test_ethIn_fallback_direct() public {
        (uint256 amountOut, address executedVenue) = router.swapViaVenueV1{value: AMOUNT_IN}(
            address(fallbackRouter),
            ETH_SENTINEL,
            address(tokenOut),
            AMOUNT_IN,
            AMOUNT_IN,
            recipient,
            block.timestamp + 1
        );

        assertEq(executedVenue, address(fallbackRouter), "should execute on the fallback");
        assertEq(amountOut, AMOUNT_IN, "fallback delivered amount");
        assertEq(tokenOut.balanceOf(recipient), AMOUNT_IN, "recipient tokenOut");
        // The fallback pulled the wrapped WETH (it transferFroms); router clean.
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH stranded in router");
        assertEq(address(router).balance, 0, "no ETH stranded in router");
    }

    // --- ETH -> venue fails -> Uniswap fallback ---------------------------

    function test_ethIn_venueFails_fallsBackToUniswap() public {
        // `deadVenue` has no code, so `_dispatchVenue` reverts (the WETH
        // safeTransfer to it rolls back) and `_coreSwap` engages the fallback.
        (uint256 amountOut, address executedVenue) = router.swapViaVenueV1{value: AMOUNT_IN}(
            address(deadVenue), ETH_SENTINEL, address(tokenOut), AMOUNT_IN, AMOUNT_IN, recipient, block.timestamp + 1
        );

        assertEq(executedVenue, address(fallbackRouter), "should fall back to Uniswap");
        assertEq(amountOut, AMOUNT_IN, "fallback delivered amount");
        assertEq(tokenOut.balanceOf(recipient), AMOUNT_IN, "recipient tokenOut");
        assertEq(IERC20(WETH).balanceOf(address(deadVenue)), 0, "rolled-back transfer left nothing at dead venue");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH stranded in router");
        assertEq(address(router).balance, 0, "no ETH stranded in router");
    }

    // --- ETH -> swapV1 auto-selects the venue -----------------------------

    function test_ethIn_swapV1_picksVenue() public {
        // Venue quotes 1:1 (AMOUNT_IN); make the fallback quote worse so the
        // venue is chosen, proving the pick-best path also wraps ETH correctly.
        quoter.setQuote(AMOUNT_IN / 2);

        (uint256 amountOut, address executedVenue) = router.swapV1{value: AMOUNT_IN}(
            ETH_SENTINEL, address(tokenOut), AMOUNT_IN, AMOUNT_IN, recipient, block.timestamp + 1
        );

        assertEq(executedVenue, address(venue), "best quote is the venue");
        assertEq(amountOut, AMOUNT_IN, "venue delivered amount");
        assertEq(tokenOut.balanceOf(recipient), AMOUNT_IN, "recipient tokenOut");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH stranded in router");
    }

    // --- msg.value guards -------------------------------------------------

    function test_ethIn_wrongMsgValueReverts() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, AMOUNT_IN, AMOUNT_IN - 1));
        router.swapViaVenueV1{value: AMOUNT_IN - 1}(
            address(venue), ETH_SENTINEL, address(tokenOut), AMOUNT_IN, AMOUNT_IN, recipient, block.timestamp + 1
        );
    }
}
