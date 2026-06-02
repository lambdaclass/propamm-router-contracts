// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";

contract MockV3SwapRouter {
    uint256 public amountOutToReturn;

    function setAmountOut(uint256 amountOut) external {
        amountOutToReturn = amountOut;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = amountOutToReturn;
        // Deliver pre-funded tokenOut to the recipient (a FoT token burns here).
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}
