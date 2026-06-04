// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, stdError} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter02} from "./mocks/MockSwapRouter02.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {FERMI_ROUTER} from "../src/interfaces/IFermiSwapper.sol";
import {KIPSELI_PAMM} from "../src/interfaces/IKipseliPAMM.sol";
import {BEBOP_ROUTER} from "../src/interfaces/IBebopRouter.sol";

contract PropAMMRouterVenueWhitelistTest is Test {
    PropAMMRouter internal router;
    MockSwapRouter02 internal mockRouter;
    MockQuoterV2 internal mockQuoter;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(this);
    address internal stranger = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    // An address that is neither a default propAMM nor the fallback, and has no
    // code. Once whitelisted it still has no working `IPropAMM` implementation, so
    // its quote/swap calls revert and execution falls through to the Uniswap
    // fallback. Lets tests exercise the whitelist gate on its own.
    address internal genericVenue = address(0xABCD);

    // Re-declared locally so vm.expectEmit can match the router's emit (mirror of
    // PropAMMRouter.VenueWhitelisted / VenueRemoved; kept in sync).
    event VenueWhitelisted(address indexed venue);
    event VenueRemoved(address indexed venue);

    function setUp() public {
        mockRouter = new MockSwapRouter02();
        mockQuoter = new MockQuoterV2();
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(mockRouter), address(mockQuoter), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(payable(address(proxy)));
    }

    // --- Seeding -----------------------------------------------------------

    function test_initialize_seedsDefaultVenues() public view {
        // A from-scratch deploy ships with the known propAMMs whitelisted.
        assertTrue(router.isWhitelistedVenue(FERMI_ROUTER));
        assertTrue(router.isWhitelistedVenue(KIPSELI_PAMM));
        assertTrue(router.isWhitelistedVenue(BEBOP_ROUTER));
    }

    function test_isWhitelistedVenue_unknownReturnsFalse() public view {
        assertFalse(router.isWhitelistedVenue(genericVenue));
    }

    function test_isWhitelistedVenue_fallbackNotWhitelisted() public view {
        // The Uniswap fallback is usable as a venue without being whitelisted, so
        // the propAMM getter reports it as not-whitelisted.
        assertFalse(router.isWhitelistedVenue(address(mockRouter)));
    }

    // --- Enumeration -------------------------------------------------------

    function test_getWhitelistedVenues_returnsDefaults() public view {
        address[] memory venues = router.getWhitelistedVenues();
        assertEq(venues.length, 3);
        // Order is not guaranteed, so assert membership.
        assertTrue(_contains(venues, FERMI_ROUTER));
        assertTrue(_contains(venues, KIPSELI_PAMM));
        assertTrue(_contains(venues, BEBOP_ROUTER));
    }

    function test_whitelistedVenueCount_defaults() public view {
        assertEq(router.whitelistedVenueCount(), 3);
    }

    function test_whitelistedVenueAt_enumeratesFullSet() public view {
        uint256 count = router.whitelistedVenueCount();
        address[] memory seen = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            seen[i] = router.whitelistedVenueAt(i);
        }
        assertTrue(_contains(seen, FERMI_ROUTER));
        assertTrue(_contains(seen, KIPSELI_PAMM));
        assertTrue(_contains(seen, BEBOP_ROUTER));
    }

    function test_whitelistedVenueAt_outOfBoundsReverts() public {
        // Resolve the count first: vm.expectRevert attaches to the very next
        // external call, which must be the out-of-bounds `whitelistedVenueAt`.
        uint256 count = router.whitelistedVenueCount();
        vm.expectRevert(stdError.indexOOBError);
        router.whitelistedVenueAt(count);
    }

    function test_addVenue_appearsInEnumeration() public {
        router.addVenue(genericVenue);
        assertEq(router.whitelistedVenueCount(), 4);
        assertTrue(_contains(router.getWhitelistedVenues(), genericVenue));
    }

    function test_removeVenue_dropsFromEnumeration() public {
        router.removeVenue(FERMI_ROUTER);
        assertEq(router.whitelistedVenueCount(), 2);
        assertFalse(_contains(router.getWhitelistedVenues(), FERMI_ROUTER));
    }

    // --- addVenue ----------------------------------------------------------

    function test_addVenue_adds() public {
        router.addVenue(genericVenue);
        assertTrue(router.isWhitelistedVenue(genericVenue));
    }

    function test_addVenue_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(router));
        emit VenueWhitelisted(genericVenue);
        router.addVenue(genericVenue);
    }

    function test_addVenue_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        router.addVenue(genericVenue);
    }

    function test_addVenue_zeroReverts() public {
        vm.expectRevert(PropAMMRouter.ZeroAddress.selector);
        router.addVenue(address(0));
    }

    function test_addVenue_duplicateReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.VenueAlreadyWhitelisted.selector, FERMI_ROUTER));
        router.addVenue(FERMI_ROUTER);
    }

    // --- removeVenue -------------------------------------------------------

    function test_removeVenue_removes() public {
        router.removeVenue(FERMI_ROUTER);
        assertFalse(router.isWhitelistedVenue(FERMI_ROUTER));
    }

    function test_removeVenue_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(router));
        emit VenueRemoved(FERMI_ROUTER);
        router.removeVenue(FERMI_ROUTER);
    }

    function test_removeVenue_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        router.removeVenue(FERMI_ROUTER);
    }

    function test_removeVenue_notWhitelistedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.VenueNotWhitelisted.selector, genericVenue));
        router.removeVenue(genericVenue);
    }

    function test_addThenRemove_roundTrips() public {
        router.addVenue(genericVenue);
        assertTrue(router.isWhitelistedVenue(genericVenue));
        router.removeVenue(genericVenue);
        assertFalse(router.isWhitelistedVenue(genericVenue));
        // Re-adding after removal works (no stale "already listed" state).
        router.addVenue(genericVenue);
        assertTrue(router.isWhitelistedVenue(genericVenue));
    }

    // --- Whitelist gates venue usage --------------------------------------

    function test_quoteVenueV1_nonWhitelistedReverts() public {
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.quoteVenueV1(genericVenue, address(tokenIn), address(tokenOut), 1 ether);
    }

    function test_quoteVenueV1_removedVenueReverts() public {
        router.removeVenue(FERMI_ROUTER);
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.quoteVenueV1(FERMI_ROUTER, address(tokenIn), address(tokenOut), 1 ether);
    }

    function test_quoteVenueV1_fallbackQuotableWithoutWhitelist() public {
        // The fallback prices without being on the whitelist (safety net).
        mockQuoter.setAmountOut(1000);
        (uint256 out,) = router.quoteVenueV1(address(mockRouter), address(tokenIn), address(tokenOut), 1 ether);
        assertEq(out, 1000);
    }

    function test_swapViaVenueV1_nonWhitelistedReverts() public {
        tokenIn.mint(address(this), 1000);
        tokenIn.approve(address(router), 1000);
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.swapViaVenueV1(
            genericVenue, address(tokenIn), address(tokenOut), 1000, 900, recipient, block.timestamp + 1
        );
    }

    function test_swapViaVenueV1_removedVenueReverts() public {
        router.removeVenue(BEBOP_ROUTER);
        tokenIn.mint(address(this), 1000);
        tokenIn.approve(address(router), 1000);
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.swapViaVenueV1(
            BEBOP_ROUTER, address(tokenIn), address(tokenOut), 1000, 900, recipient, block.timestamp + 1
        );
    }

    function test_swapViaVenueV1_afterAdd_passesGateAndFallsBack() public {
        // Whitelisting `genericVenue` lets the call clear the `_isVenue` gate.
        // The address has no code, so `_dispatchVenue` reverts and the swap routes
        // transparently through the Uniswap fallback; the swap succeeding confirms
        // the gate opened rather than the venue itself executing.
        router.addVenue(genericVenue);
        mockRouter.setAmountOut(1000);
        tokenIn.mint(address(this), 1000);
        tokenIn.approve(address(router), 1000);

        (uint256 amountOut, ) = router.swapViaVenueV1(
            genericVenue, address(tokenIn), address(tokenOut), 1000, 900, recipient, block.timestamp + 1
        );

        assertEq(amountOut, 1000);
        assertEq(tokenOut.balanceOf(recipient), 1000);
    }

    // --- Helpers -----------------------------------------------------------

    function _contains(address[] memory arr, address target) private pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == target) return true;
        }
        return false;
    }
}
