// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {FERMI_ROUTER} from "../src/interfaces/IFermiSwapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {MockFermi, MockFermiReverting} from "./mocks/MockFermi.sol";

/// @title PropAMMRouterFermiTest
/// @notice Covers the bespoke FermiSwap dispatch (`fermiSwapWithAllowances` /
/// `quoteAmounts`, taken when `venue == FERMI_ROUTER`). The fork test exercises
/// the live router's *deployed bytecode*, which dispatches the migrated Fermi
/// venue generically; this suite instead etches a `MockFermi` at `FERMI_ROUTER`
/// so the local source's bespoke branch is actually executed and verified.
contract PropAMMRouterFermiTest is Test {
    PropAMMRouter router;
    AccessManager manager;
    MockV3SwapRouter swapRouter;
    MockQuoterV2 quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        swapRouter = new MockV3SwapRouter();
        quoter = new MockQuoterV2();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");

        // Plain AccessManager with `owner` as delay-0 admin (unmapped selectors
        // default to ADMIN_ROLE), so config calls are unnecessary here.
        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data =
            abi.encodeCall(PropAMMRouter.initialize, (address(swapRouter), address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), data))));

        // Place the bespoke Fermi mock at the hard-coded FERMI_ROUTER address so
        // the contract's `venue == FERMI_ROUTER` branch routes through it.
        vm.etch(FERMI_ROUTER, address(new MockFermi()).code);
    }

    /// Funds the user with `amountIn` tokenIn (+ router approval) and the Fermi
    /// mock with the `delivered` tokenOut it quotes and pays out.
    function _prepare(uint256 amountIn, uint256 delivered) internal {
        tokenIn.mint(user, amountIn);
        tokenOut.mint(FERMI_ROUTER, delivered);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
    }

    function test_quoteVenueV1_fermi_usesBespokeQuoter() public {
        tokenOut.mint(FERMI_ROUTER, 1_100e18);

        (uint256 amountOut, address quotedVenue) =
            router.quoteVenueV1(FERMI_ROUTER, address(tokenIn), address(tokenOut), 1_000e18);

        // Came from IFermiSwapper.quoteAmounts (bespoke), not the Uniswap fallback.
        assertEq(amountOut, 1_100e18, "fermi bespoke quote");
        assertEq(quotedVenue, FERMI_ROUTER, "quoted venue is fermi, not the fallback");
    }

    function test_swapViaVenueV1_fermi_executesViaBespokePath() public {
        _prepare(1_000e18, 1_100e18);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) = router.swapViaVenueV1(
            FERMI_ROUTER, address(tokenIn), address(tokenOut), 1_000e18, 1_100e18, user, block.timestamp + 1
        );

        assertEq(executedVenue, FERMI_ROUTER, "executed via fermi, not the uniswap fallback");
        assertEq(amountOut, 1_100e18, "delivered amount");
        assertEq(tokenOut.balanceOf(user), 1_100e18, "user received tokenOut");
        assertEq(tokenIn.balanceOf(FERMI_ROUTER), 1_000e18, "fermi pulled tokenIn via the allowance");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        // `_dispatchVenue` resets the venue allowance after the swap (forceApprove(.., 0)).
        assertEq(tokenIn.allowance(address(router), FERMI_ROUTER), 0, "venue allowance reset");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
    }

    function test_swapV1_autoSelectsFermi_overFallback() public {
        // Fermi quotes 1_100e18; the Uniswap fallback only 1_000e18 -> Fermi wins
        // in `_pickBestVenue` (Bebop/Kipseli have no code, so they revert and are skipped).
        _prepare(1_000e18, 1_100e18);
        quoter.setQuote(1_000e18);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), 1_000e18, 1_000e18, user, block.timestamp + 1);

        assertEq(executedVenue, FERMI_ROUTER, "swapV1 routed through fermi's bespoke path");
        assertEq(amountOut, 1_100e18, "delivered the fermi amount");
        assertEq(tokenOut.balanceOf(user), 1_100e18);
    }

    function test_swapViaVenueWithFeeV1_fermi_skimsFee() public {
        uint256 delivered = 1_000e18;
        _prepare(delivered, delivered);
        uint256 fee = delivered * 50 / 10_000; // 0.5%
        uint256 net = delivered - fee;

        vm.prank(user);
        uint256 amountOut = router.swapViaVenueWithFeeV1(
            FERMI_ROUTER,
            address(tokenIn),
            address(tokenOut),
            delivered,
            net,
            user,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: feeRecipient})
        );

        assertEq(amountOut, net, "net delivered to user");
        assertEq(tokenOut.balanceOf(user), net);
        assertEq(tokenOut.balanceOf(feeRecipient), fee);
        assertEq(tokenOut.balanceOf(address(router)), 0);
    }

    /// A reverting Fermi (venue down / wrong interface) must NOT bubble up:
    /// `_coreSwap` wraps `_dispatchVenue` in a try/catch so the bespoke
    /// `venue == FERMI_ROUTER` arm degrades to the always-available Uniswap
    /// fallback. `executedVenue == address(swapRouter)` (not `FERMI_ROUTER`)
    /// proves the catch arm engaged.
    function test_swapViaVenueV1_fermiReverts_fallsBackToUniswap() public {
        // Replace the happy-path mock with one whose entrypoints revert.
        vm.etch(FERMI_ROUTER, address(new MockFermiReverting()).code);

        uint256 amountIn = 1_000e18;
        uint256 fallbackOut = 990e18;
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);

        // Fund + arm the Uniswap fallback (the swap router) to deliver `fallbackOut`.
        tokenOut.mint(address(swapRouter), fallbackOut);
        swapRouter.setAmountOut(fallbackOut);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) = router.swapViaVenueV1(
            FERMI_ROUTER, address(tokenIn), address(tokenOut), amountIn, fallbackOut, user, block.timestamp + 1
        );

        assertEq(executedVenue, address(swapRouter), "fell back to the Uniswap venue, not fermi");
        assertEq(amountOut, fallbackOut, "delivered the fallback amount");
        assertEq(tokenOut.balanceOf(user), fallbackOut, "user received the fallback output");
        // The reverting venue pulled nothing; the fallback consumed the tokenIn.
        assertEq(tokenIn.balanceOf(FERMI_ROUTER), 0, "reverting fermi pulled no tokenIn");
        assertEq(tokenIn.balanceOf(address(swapRouter)), amountIn, "fallback pulled the tokenIn");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(tokenIn.allowance(address(router), FERMI_ROUTER), 0, "no residual fermi allowance");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
    }

    /// Fermi filling BELOW `amountOutMin` must also fall back: `_dispatchVenue`
    /// re-checks the delivered delta and reverts, and the same `_coreSwap`
    /// try/catch turns that into the Uniswap fallback. The revert rolls back BOTH
    /// the under-delivered `tokenOut` and the `tokenIn` the venue pulled, so the
    /// router is left whole for the fallback — asserted via the restored balances.
    function test_swapViaVenueV1_fermiUnderDelivers_fallsBackToUniswap() public {
        uint256 amountIn = 1_000e18;
        uint256 fermiShort = 500e18; // below amountOutMin -> _dispatchVenue reverts
        uint256 amountOutMin = 990e18;
        uint256 fallbackOut = 990e18;

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);

        // The happy-path mock (etched in setUp) delivers its whole tokenOut
        // balance; fund it short so the delivered delta misses `amountOutMin`.
        tokenOut.mint(FERMI_ROUTER, fermiShort);

        // Arm the fallback to clear `amountOutMin`.
        tokenOut.mint(address(swapRouter), fallbackOut);
        swapRouter.setAmountOut(fallbackOut);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) = router.swapViaVenueV1(
            FERMI_ROUTER, address(tokenIn), address(tokenOut), amountIn, amountOutMin, user, block.timestamp + 1
        );

        assertEq(executedVenue, address(swapRouter), "under-fill fell back to Uniswap");
        assertEq(amountOut, fallbackOut, "delivered the fallback amount");
        assertEq(tokenOut.balanceOf(user), fallbackOut, "user received only the fallback output");
        // The under-delivery (and the venue's tokenIn pull) were rolled back.
        assertEq(tokenOut.balanceOf(FERMI_ROUTER), fermiShort, "fermi's tokenOut roll back intact");
        assertEq(tokenIn.balanceOf(FERMI_ROUTER), 0, "fermi's tokenIn pull rolled back");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router holds no tokenIn");
        assertEq(tokenOut.balanceOf(address(router)), 0, "router holds no tokenOut");
    }
}
