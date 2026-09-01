// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockLinearSwapRouter, MockLinearQuoterV2} from "./mocks/MockLinearUniswap.sol";

contract MockVenueSanityTest is Test {
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockCappedPropAMM venue;

    function setUp() public {
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        venue = new MockCappedPropAMM(1, 2); // out = in * 2
        tokenOut.mint(address(venue), 1_000_000e18);
    }

    function test_quote_linearBelowCap() public {
        venue.setCap(100e18);
        assertEq(venue.quote(address(tokenIn), address(tokenOut), 50e18), 100e18);
    }

    function test_quote_hardRevertAboveCap() public {
        venue.setCap(100e18);
        venue.setCapMode(MockCappedPropAMM.CapMode.HardRevert);
        vm.expectRevert(bytes("cap"));
        venue.quote(address(tokenIn), address(tokenOut), 200e18);
    }

    function test_quote_saturatesAboveCap() public {
        venue.setCap(100e18);
        venue.setCapMode(MockCappedPropAMM.CapMode.Saturate);
        // Fixed max output (cap * 2) regardless of oversized input — the Fermi behavior.
        assertEq(venue.quote(address(tokenIn), address(tokenOut), 200e18), 200e18);
        assertEq(venue.quote(address(tokenIn), address(tokenOut), 900e18), 200e18);
    }

    function test_quote_zeroAboveCap() public {
        venue.setCap(100e18);
        venue.setCapMode(MockCappedPropAMM.CapMode.ZeroQuote);
        assertEq(venue.quote(address(tokenIn), address(tokenOut), 200e18), 0);
    }

    function test_swap_deliversAtLinearPrice() public {
        tokenIn.mint(address(venue), 50e18); // push-payment: input already at venue
        uint256 out = venue.swap(address(tokenIn), address(tokenOut), 50e18, 0, address(this), 0);
        assertEq(out, 100e18);
        assertEq(tokenOut.balanceOf(address(this)), 100e18);
    }

    function test_swap_shortChangeIgnoresMinWhenConfigured() public {
        venue.setHonorMinOut(false);
        venue.setShortChangeBps(1_000); // delivers 10% under quote
        tokenIn.mint(address(venue), 50e18);
        uint256 out = venue.swap(address(tokenIn), address(tokenOut), 50e18, 100e18, address(this), 0);
        assertEq(out, 90e18);
    }

    function test_linearUniswap_swapAndQuoteAgree() public {
        MockLinearSwapRouter uni = new MockLinearSwapRouter();
        MockLinearQuoterV2 quoter = new MockLinearQuoterV2();
        uni.setPrice(1, 3);
        quoter.setPrice(1, 3);
        assertEq(quoter.quote(100e18), 300e18);
        tokenIn.mint(address(this), 100e18);
        tokenIn.approve(address(uni), 100e18);
        uint256 out = uni.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: 3000,
                recipient: address(this),
                amountIn: 100e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        assertEq(out, 300e18);
        assertEq(tokenOut.balanceOf(address(this)), 300e18);
    }
}
