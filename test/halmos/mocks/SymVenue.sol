// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMM} from "../../../src/interfaces/IPropAMM.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice A propAMM venue with NO assumed behaviour. Every quote is a fresh
/// symbolic value, unrelated to any other quote, so the venue's prices can be
/// linear, saturating, inconsistent or absurd. Every swap delivers a fresh
/// symbolic amount, whatever it quoted. A property proven against this mock
/// holds for every venue priced through the blind probe (see below).
/// @dev Records what happened so a check can state facts about the run:
///   - every quote, as (size, value);
///   - every swap that SURVIVED, as (input received, output delivered). A swap
///     the router rejects (under-delivery against the leg's `minOut`) reverts
///     the router's `_dispatchVenue` frame, which erases its record too — so
///     the records are exactly the legs that executed.
/// No `supportsInterface`: `ERC165Checker` sees a revert, so the router prices
/// this venue through the blind two-point probe, not `IPropAMMFillable`. For
/// the fillable path, see `SymFillableVenue`.
contract SymVenue is IPropAMM, SymTest {
    uint256[] public quoteSizes;
    uint256[] public quoteOuts;
    uint256[] public swapIns;
    uint256[] public swapOuts;

    function quoteCount() external view returns (uint256) {
        return quoteSizes.length;
    }

    function swapCount() external view returns (uint256) {
        return swapIns.length;
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory pairs) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256 amountIn) external returns (uint256 out) {
        out = svm.createUint256("venue.quote");
        quoteSizes.push(amountIn);
        quoteOuts.push(out);
    }

    /// @dev Input is measured from this venue's balance, not trusted from the
    /// argument: the router pushes the leg's tokens before calling `swap`.
    function swap(address tokenIn, address tokenOut, uint256, uint256, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        uint256 received = IERC20(tokenIn).balanceOf(address(this));
        for (uint256 i = 0; i < swapIns.length; i++) {
            received -= swapIns[i];
        }
        amountOut = svm.createUint256("venue.out");
        MockERC20(tokenOut).mint(recipient, amountOut);
        swapIns.push(received);
        swapOuts.push(amountOut);
    }
}
