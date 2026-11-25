// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../../src/PropAMMRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SymUniswap} from "./mocks/SymUniswap.sol";
import {SymNastyVenue} from "./mocks/SymNastyVenue.sol";

/// @title Custody of `swapSplitV1`: nobody's tokens go missing
/// @notice For EVERY behaviour of the whitelisted venues — including venues
/// that try to pull tokens from the router, push tokens into it, keep or refund
/// part of their input, and quote or deliver anything — every `swapSplitV1`
/// that does not revert ends with:
///   K1  the user paid exactly `amountIn`, and nothing else;
///   K2  the recipient received exactly the returned `amountOut`, and
///       `amountOut >= amountOutMin`;
///   K3  every unit of `amountIn` went to an executed venue leg or to the
///       Uniswap leg: Σ venue leg inputs + Uniswap input == amountIn;
///   K4  no venue managed to pull anything out of the router;
///   K5  the router's balance of each token changed by exactly what venues
///       pushed into it — so it kept none of the user's input or output, and
///       lost none of the tokens it already held (arbitrary pre-existing dust);
///   K6  the router has no allowance left to any venue or to Uniswap.
///
/// A call that reverts moves nothing (EVM atomicity), so it needs no check.
///
/// Nothing is assumed about Uniswap's prices; `SymUniswap` only makes the swap
/// pull exactly its `amountIn`, as the real `SwapRouter02` does.
///
/// @dev Bounded to ONE whitelisted venue: with two, the blind-probe check
/// alone would need far more than its single-venue hour. Out of scope: the ETH
/// sentinel paths (WETH wrap/unwrap) and `swapSplitWithFeeV1`.
contract SplitCustodyHalmos is Test, SymTest {
    PropAMMRouter internal router;
    SymUniswap internal uni;
    MockERC20 internal tin;
    MockERC20 internal tout;
    SymNastyVenue[] internal venues;

    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        uni = new SymUniswap();
        tin = new MockERC20("TokenIn", "TIN");
        tout = new MockERC20("TokenOut", "TOUT");

        AccessManager manager = new AccessManager(address(this));
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(uni), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    /// @dev Blind two-point probe. ~48k paths, about an hour: too slow for
    /// CI, run it locally.
    function check_custody_oneVenue(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(false), amountIn, amountOutMin);
    }

    /// @dev `IPropAMMFillable.quoteFillable`. ~6k paths, about 6 minutes.
    function check_custody_oneFillableVenue(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(true), amountIn, amountOutMin);
    }

    function _venue(bool fillable) internal returns (uint256 n) {
        SymNastyVenue v = new SymNastyVenue(address(router), fillable);
        venues.push(v);
        router.addVenue(address(v));
        return 1;
    }

    function _checkCustody(uint256 n, uint256 a, uint256 amountOutMin) internal {
        // Arbitrary tokens already sitting in the router (stranded dust,
        // donations awaiting `rescueTokens`): the split must not touch them.
        // Amounts are capped so no mint can overflow a total supply (that
        // would only revert, and fork a path per mint).
        tin.mint(address(router), uint128(svm.createUint256("dustIn")));
        tout.mint(address(router), uint128(svm.createUint256("dustOut")));
        uint256 routerIn0 = tin.balanceOf(address(router));
        uint256 routerOut0 = tout.balanceOf(address(router));

        // The user holds more than the order, so "paid exactly amountIn" is
        // not true merely because the balance hit zero.
        uint256 userIn0 = uint128(svm.createUint256("userIn"));
        vm.assume(userIn0 >= a);
        tin.mint(USER, userIn0);
        vm.prank(USER);
        tin.approve(address(router), type(uint256).max);

        vm.prank(USER);
        uint256 amountOut =
            router.swapSplitV1(address(tin), address(tout), a, amountOutMin, RECIPIENT, type(uint256).max);

        assertEq(tin.balanceOf(USER), userIn0 - a, "K1: user paid other than amountIn");
        assertEq(tout.balanceOf(USER), 0, "K1: user received tokenOut");

        assertEq(tout.balanceOf(RECIPIENT), amountOut, "K2: recipient received other than amountOut");
        assertGe(amountOut, amountOutMin, "K2: amountOut below amountOutMin");

        uint256 legInputs;
        uint256 pushedIn;
        uint256 pushedOut;
        for (uint256 i = 0; i < n; i++) {
            SymNastyVenue v = venues[i];
            legInputs += v.legInput();
            pushedIn += v.pushedToRouter(address(tin));
            pushedOut += v.pushedToRouter(address(tout));
            assertEq(v.pulledFromRouter(address(tin)), 0, "K4: venue pulled tokenIn from the router");
            assertEq(v.pulledFromRouter(address(tout)), 0, "K4: venue pulled tokenOut from the router");
            assertEq(tin.allowance(address(router), address(v)), 0, "K6: tokenIn allowance left to a venue");
            assertEq(tout.allowance(address(router), address(v)), 0, "K6: tokenOut allowance left to a venue");
        }
        uint256 uniInput;
        for (uint256 j = 0; j < uni.swapCount(); j++) {
            uniInput += uni.swapIns(j);
        }
        assertEq(legInputs + uniInput, a, "K3: legs did not spend exactly amountIn");

        assertEq(tin.balanceOf(address(router)), routerIn0 + pushedIn, "K5: router tokenIn balance off");
        assertEq(tout.balanceOf(address(router)), routerOut0 + pushedOut, "K5: router tokenOut balance off");

        assertEq(tin.allowance(address(router), address(uni)), 0, "K6: tokenIn allowance left to Uniswap");
        assertEq(tout.allowance(address(router), address(uni)), 0, "K6: tokenOut allowance left to Uniswap");
    }
}
