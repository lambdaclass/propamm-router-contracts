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
import {SymWETH} from "./mocks/SymWETH.sol";
import {IPropAMMRouter} from "../../src/interfaces/IPropAMMRouter.sol";
import {ETH_SENTINEL, WETH} from "../../src/libraries/Constants.sol";

/// @title Custody of the split entrypoints: nobody's tokens go missing
/// @notice For EVERY behaviour of the whitelisted venues — including venues
/// that try to pull tokens from the router, push tokens into it, keep or refund
/// part of their input, and quote or deliver anything — every `swapSplitV1` /
/// `swapSplitWithFeeV1` that does not revert ends with:
///   K1  the user paid exactly `amountIn`, and nothing else;
///   K2  the recipient received exactly the returned `amountOut`, and
///       `amountOut >= amountOutMin`; with a frontend fee, the fee recipient
///       received exactly `gross * bps / 10_000` of the gross the legs
///       delivered, and the recipient exactly the rest;
///   K3  every unit of `amountIn` went to an executed venue leg or to the
///       Uniswap leg: Σ venue leg inputs + Uniswap input == amountIn;
///   K4  no venue managed to pull anything out of the router;
///   K5  the router's balance of each token changed by exactly what venues
///       pushed into it, and its ETH balance did not change at all — so it
///       kept none of the user's input or output, and lost none of what it
///       already held (arbitrary pre-existing dust, ETH included);
///   K6  the router has no allowance left to any venue or to Uniswap.
///
/// A call that reverts moves nothing (EVM atomicity), so it needs no check.
///
/// Nothing is assumed about Uniswap's prices; `SymUniswap` only makes the swap
/// pull exactly its `amountIn`, as the real `SwapRouter02` does.
///
/// Covered: ERC-20 in and out, ETH in (wrapped to WETH), ETH out (unwrapped
/// from WETH), and the frontend-fee entrypoint, with the fee in a token or in
/// ETH. WETH is `SymWETH`, etched at the address the router hard-codes.
///
/// @dev Bounded to ONE whitelisted venue: with two, the blind-probe check
/// alone would need far more than its single-venue hour. The ETH and fee
/// variants use the `IPropAMMFillable` venue only, which is ~10x cheaper; the
/// code they add (wrap, unwrap, fee skim) runs after pricing, so it does not
/// depend on which pricing path chose the legs.
contract SplitCustodyHalmos is Test, SymTest {
    PropAMMRouter internal router;
    SymUniswap internal uni;
    MockERC20 internal erc20In;
    MockERC20 internal erc20Out;
    MockERC20 internal weth;
    SymNastyVenue[] internal venues;

    // Set per check: the tokens the legs actually trade (WETH on an ETH side).
    MockERC20 internal tin;
    MockERC20 internal tout;

    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);
    address internal constant FEE_TO = address(0xFEE0);

    struct Mode {
        bool ethIn;
        bool ethOut;
        bool withFee;
    }

    function setUp() public {
        uni = new SymUniswap();
        erc20In = new MockERC20("TokenIn", "TIN");
        erc20Out = new MockERC20("TokenOut", "TOUT");

        vm.etch(WETH, address(new SymWETH()).code);
        weth = MockERC20(WETH);
        // Halmos caps every ETH balance at 2^128 (`MAX_ETH`) and errors past
        // it, so ETH is budgeted to keep the whole system under the cap: WETH's
        // reserve 2^127, router dust < 2^64, user < 2^96, payees start at 0.
        // A withdrawal beyond the reserve just reverts (and drops that path).
        vm.deal(WETH, 1 << 127);
        vm.deal(RECIPIENT, 0);
        vm.deal(FEE_TO, 0);

        AccessManager manager = new AccessManager(address(this));
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(uni), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    /// @dev Blind two-point probe. ~48k paths, about an hour: too slow for
    /// CI, run it locally.
    function check_custody_oneVenue(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(false), Mode(false, false, false), amountIn, amountOutMin);
    }

    /// @dev `IPropAMMFillable.quoteFillable`. ~6k paths, about 6 minutes.
    function check_custody_oneFillableVenue(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(true), Mode(false, false, false), amountIn, amountOutMin);
    }

    // The four below are local-only (5-27 min each here, ~4x that on CI's
    // hosted runners). Timings in test/halmos/README.md.

    function check_custody_ethIn(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(true), Mode(true, false, false), amountIn, amountOutMin);
    }

    function check_custody_ethOut(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(true), Mode(false, true, false), amountIn, amountOutMin);
    }

    function check_custody_fee(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(true), Mode(false, false, true), amountIn, amountOutMin);
    }

    /// @dev The fee leaves the router as ETH, by a raw `call`.
    function check_custody_feeEthOut(uint256 amountIn, uint256 amountOutMin) public {
        _checkCustody(_venue(true), Mode(false, true, true), amountIn, amountOutMin);
    }

    function _venue(bool fillable) internal returns (uint256 n) {
        SymNastyVenue v = new SymNastyVenue(address(router), fillable);
        venues.push(v);
        router.addVenue(address(v));
        return 1;
    }

    /// @dev What `who` holds of the user-facing output: ETH or `tout`.
    function _out(Mode memory m, address who) internal view returns (uint256) {
        return m.ethOut ? who.balance : tout.balanceOf(who);
    }

    function _checkCustody(uint256 n, Mode memory m, uint256 a, uint256 amountOutMin) internal {
        tin = m.ethIn ? weth : erc20In;
        tout = m.ethOut ? weth : erc20Out;

        // Arbitrary tokens and ETH already sitting in the router (stranded
        // dust, donations awaiting `rescueTokens`): the split must not touch
        // them. Amounts are capped so no mint can overflow a total supply
        // (that would only revert, and fork a path per mint).
        tin.mint(address(router), uint128(svm.createUint256("dustIn")));
        tout.mint(address(router), uint128(svm.createUint256("dustOut")));
        vm.deal(address(router), uint64(svm.createUint256("dustEth")));
        uint256 routerIn0 = tin.balanceOf(address(router));
        uint256 routerOut0 = tout.balanceOf(address(router));
        uint256 routerEth0 = address(router).balance;

        // The user holds more than the order, so "paid exactly amountIn" is
        // not true merely because the balance hit zero.
        uint256 user0 = m.ethIn ? uint96(svm.createUint256("userIn")) : uint128(svm.createUint256("userIn"));
        vm.assume(user0 >= a);
        if (m.ethIn) {
            vm.deal(USER, user0);
        } else {
            tin.mint(USER, user0);
            vm.prank(USER);
            tin.approve(address(router), type(uint256).max);
        }
        if (!m.ethIn) vm.deal(USER, 0);
        uint256 userEth0 = USER.balance;

        uint256 recipient0 = _out(m, RECIPIENT);
        uint256 feeTo0 = _out(m, FEE_TO);
        uint16 bps = uint16(svm.createUint256("feeBps"));

        uint256 amountOut = _swap(m, a, amountOutMin, bps);

        // K1
        if (m.ethIn) {
            assertEq(USER.balance, userEth0 - a, "K1: user paid other than amountIn ETH");
        } else {
            assertEq(tin.balanceOf(USER), user0 - a, "K1: user paid other than amountIn");
            assertEq(USER.balance, userEth0, "K1: user's ETH changed");
        }

        // K2
        uint256 toRecipient = _out(m, RECIPIENT) - recipient0;
        assertEq(toRecipient, amountOut, "K2: recipient received other than amountOut");
        assertGe(amountOut, amountOutMin, "K2: amountOut below amountOutMin");
        if (m.withFee) {
            uint256 fee = _out(m, FEE_TO) - feeTo0;
            assertEq(fee, (toRecipient + fee) * bps / 10_000, "K2: fee is not bps of the gross");
        }

        // K3, K4, K6 (venues)
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

        // K5
        assertEq(tin.balanceOf(address(router)), routerIn0 + pushedIn, "K5: router tokenIn balance off");
        assertEq(tout.balanceOf(address(router)), routerOut0 + pushedOut, "K5: router tokenOut balance off");
        assertEq(address(router).balance, routerEth0, "K5: router ETH balance changed");

        // K6 (Uniswap)
        assertEq(tin.allowance(address(router), address(uni)), 0, "K6: tokenIn allowance left to Uniswap");
        assertEq(tout.allowance(address(router), address(uni)), 0, "K6: tokenOut allowance left to Uniswap");
    }

    function _swap(Mode memory m, uint256 a, uint256 amountOutMin, uint16 bps) internal returns (uint256) {
        address inArg = m.ethIn ? ETH_SENTINEL : address(tin);
        address outArg = m.ethOut ? ETH_SENTINEL : address(tout);
        uint256 value = m.ethIn ? a : 0;
        vm.prank(USER);
        if (m.withFee) {
            return router.swapSplitWithFeeV1{value: value}(
                inArg,
                outArg,
                a,
                amountOutMin,
                RECIPIENT,
                type(uint256).max,
                IPropAMMRouter.FrontendFee({bps: bps, recipient: FEE_TO})
            );
        }
        return router.swapSplitV1{value: value}(inArg, outArg, a, amountOutMin, RECIPIENT, type(uint256).max);
    }
}
