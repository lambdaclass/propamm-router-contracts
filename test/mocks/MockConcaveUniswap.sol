// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A constant-product stand-in for SwapRouter02 + QuoterV2, whose unit
/// rate FALLS with size. Required for the waterfall's reference-refinement
/// branch: a linear quoter makes `refSize` cancel out of the cutoff predicate
/// (`out * refSize <= refOut * fill` holds identically at every size), so that
/// branch is unreachable with a linear mock and would sit untested.
///
/// Encodes against the real `IQuoterV2` / `IV3SwapRouter` param structs
/// (matching `test/mocks/MockQuoterV2.sol` / `MockSwapRouter02.sol`) rather
/// than locally-declared lookalikes, so a field-order drift in those
/// interfaces cannot silently desync this mock from what `UniV3Router`
/// actually encodes.
///
/// out = reserveOut * amountIn / (reserveIn + amountIn)
contract MockConcaveUniswap {
    uint256 public reserveIn = 1_000_000e18;
    uint256 public reserveOut = 1_000_000e18;

    function setReserves(uint256 rin, uint256 rout) external {
        reserveIn = rin;
        reserveOut = rout;
    }

    function _out(uint256 amountIn) internal view returns (uint256) {
        return reserveOut * amountIn / (reserveIn + amountIn);
    }

    // --- QuoterV2 surface ---------------------------------------------------

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory params)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        return (_out(params.amountIn), 0, 0, 0);
    }

    // --- SwapRouter02 surface -----------------------------------------------

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = _out(params.amountIn);
        require(amountOut >= params.amountOutMinimum, "uni: under min");
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}
