// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {BaseTest} from "./Base.t.sol";
import {MockFermi, MockKipseliPamm, MockKipseliQuoter, MockBebop} from "./mocks/MockVenues.sol";
import {FermiAdapter} from "../src/adapters/FermiAdapter.sol";
import {KipseliAdapter} from "../src/adapters/KipseliAdapter.sol";
import {BebopAdapter} from "../src/adapters/BebopAdapter.sol";

/// @notice End-to-end: the three real adapters (wrapping mock venues) registered
/// on the router and exercised through the public swap entrypoints.
contract IntegrationTest is BaseTest {
    MockFermi internal fermi;
    FermiAdapter internal fermiAdapter;
    MockKipseliPamm internal kpamm;
    MockKipseliQuoter internal kquoter;
    KipseliAdapter internal kipseliAdapter;
    MockBebop internal bebop;
    BebopAdapter internal bebopAdapter;

    address internal recipient = makeAddr("recipient");
    uint256 internal constant AMOUNT_IN = 100 ether;
    uint256 internal deadline;

    function setUp() public override {
        super.setUp();
        deadline = block.timestamp + 100;

        fermi = new MockFermi();
        tokenOut.mint(address(fermi), LIQUIDITY);
        fermiAdapter = new FermiAdapter(address(fermi));

        kpamm = new MockKipseliPamm();
        tokenOut.mint(address(kpamm), LIQUIDITY);
        kquoter = new MockKipseliQuoter();
        kipseliAdapter = new KipseliAdapter(address(kpamm), address(kquoter));

        bebop = new MockBebop();
        tokenOut.mint(address(bebop), LIQUIDITY);
        bebopAdapter = new BebopAdapter(address(bebop));

        vm.startPrank(owner);
        router.addPropAMM(address(fermiAdapter));
        router.addPropAMM(address(kipseliAdapter));
        router.addPropAMM(address(bebopAdapter));
        vm.stopPrank();
    }

    function test_swapV1_routesThroughBestAdapter() public {
        fermi.setOutput(200 ether);
        kpamm.setOutput(250 ether);
        kquoter.setQuote(250 ether);
        bebop.setOutput(180 ether);
        mockQuoter.setQuote(150 ether);
        _fundUser(AMOUNT_IN);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, 250 ether, recipient, deadline);

        assertEq(executedVenue, address(kipseliAdapter)); // best quote wins
        assertEq(amountOut, 250 ether);
        assertEq(tokenOut.balanceOf(recipient), 250 ether);
    }

    function test_swapViaVenueV1_throughBebopAdapter() public {
        bebop.setOutput(180 ether);
        _fundUser(AMOUNT_IN);

        vm.prank(user);
        uint256 amountOut = router.swapViaVenueV1(
            address(bebopAdapter), address(tokenIn), address(tokenOut), AMOUNT_IN, 180 ether, recipient, deadline
        );

        assertEq(amountOut, 180 ether);
        assertEq(tokenOut.balanceOf(recipient), 180 ether);
    }

    function test_swapV1_fallsBackWhenWinningAdapterCannotDeliver() public {
        // Fermi quotes highest but cannot actually deliver (output exceeds its
        // balance), so its swap reverts and the Uniswap fallback runs.
        fermi.setOutput(LIQUIDITY + 1 ether);
        kpamm.setOutput(0);
        kquoter.setQuote(0);
        bebop.setOutput(0);
        mockQuoter.setQuote(150 ether);
        mockSwapRouter.setOutput(150 ether);
        _fundUser(AMOUNT_IN);

        vm.prank(user);
        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), AMOUNT_IN, 150 ether, recipient, deadline);

        assertEq(executedVenue, fallbackSwapRouter);
        assertEq(amountOut, 150 ether);
        assertEq(tokenOut.balanceOf(recipient), 150 ether);
    }
}
