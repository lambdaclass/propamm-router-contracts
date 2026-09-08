// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Linear-rate SwapRouter02 stand-in: pulls tokenIn, mints tokenOut at
/// a configurable flat rate. Size-independent rate lets split tests reason
/// about the Uniswap reference deterministically.
contract MockLinearSwapRouter {
    uint256 public priceNum = 1;
    uint256 public priceDen = 1; // out = in * priceDen / priceNum

    function setPrice(uint256 num, uint256 den) external {
        priceNum = num;
        priceDen = den;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * priceDen / priceNum;
        require(amountOut >= params.amountOutMinimum, "uni-slippage");
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}

/// @notice Linear-rate QuoterV2 stand-in matching MockLinearSwapRouter.
contract MockLinearQuoterV2 {
    uint256 public priceNum = 1;
    uint256 public priceDen = 1;

    function setPrice(uint256 num, uint256 den) external {
        priceNum = num;
        priceDen = den;
    }

    function quote(uint256 amountIn) public view returns (uint256) {
        return amountIn * priceDen / priceNum;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata params)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        return (quote(params.amountIn), 0, 0, 0);
    }
}
