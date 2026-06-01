// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @notice Mock of Uniswap V3 SwapRouter02's `exactInputSingle`, used as the
/// router's fallback venue.
/// @dev Pulls `amountIn` from the caller (the router, which approves it) and
/// delivers a configurable `output` of `tokenOut` to the recipient. Must be
/// pre-funded with `tokenOut`.
contract MockSwapRouter {
    uint256 public output;
    bool public revertOnSwap;

    function setOutput(uint256 o) external {
        output = o;
    }

    function setRevertOnSwap(bool r) external {
        revertOnSwap = r;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(!revertOnSwap, "MockSwapRouter: reverted");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        require(output >= p.amountOutMinimum, "MockSwapRouter: Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, output);
        return output;
    }
}

/// @notice Mock of Uniswap V3 QuoterV2's `quoteExactInputSingle`, used to price
/// the router's fallback venue.
contract MockQuoter {
    uint256 public quoteOut;
    bool public revertOnQuote;

    function setQuote(uint256 q) external {
        quoteOut = q;
    }

    function setRevertOnQuote(bool r) external {
        revertOnQuote = r;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory)
        external
        view
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        require(!revertOnQuote, "MockQuoter: no pool");
        return (quoteOut, 0, 0, 0);
    }
}
