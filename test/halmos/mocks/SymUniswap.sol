// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice A Uniswap fallback whose price curve `U` is an UNKNOWN function,
/// sampled lazily. The first time a size `x` is asked about — by the quoter or
/// by the swap — `U(x)` becomes a fresh symbolic value; every later question
/// about the same `x` gets the same answer.
/// @dev Serves as BOTH `fallbackQuoter` and `fallbackSwapRouter`, reading one
/// table, which is what encodes "the quoter reports what the swap pays" and
/// "nothing moves the pool during the transaction". Every other property of
/// `U` is NOT built in: the check states it as an assumption over the sampled
/// points (see `sizes`/`outs`), so the assumption stays visible at the call
/// site instead of hiding inside the mock.
contract SymUniswap is SymTest {
    uint256[] public sizes;
    uint256[] public outs;
    /// @notice Inputs of the swaps that actually executed (the router runs at
    /// most one: failed and remainder legs are coalesced).
    uint256[] public swapIns;

    function swapCount() external view returns (uint256) {
        return swapIns.length;
    }

    function sampleCount() external view returns (uint256) {
        return sizes.length;
    }

    /// @notice `U(x)`: the curve at `x`, created on first use.
    function U(uint256 x) public returns (uint256 y) {
        for (uint256 i = 0; i < sizes.length; i++) {
            if (sizes[i] == x) return outs[i];
        }
        y = svm.createUint256("U");
        sizes.push(x);
        outs.push(y);
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata p)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 ticksCrossed, uint256 gasEstimate)
    {
        amountOut = U(p.amountIn);
        (sqrtPriceX96After, ticksCrossed, gasEstimate) = (0, 0, 0);
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = U(p.amountIn);
        require(amountOut >= p.amountOutMinimum, "Too little received");
        swapIns.push(p.amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
