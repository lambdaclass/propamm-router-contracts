// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal SwapRouter02 stand-in. Records the fee tier it was called
/// with and delivers a configurable amountOut of tokenOut to the recipient.
contract MockSwapRouter02 {
    uint24 public lastFee;
    uint256 public amountOutToReturn;

    function setAmountOut(uint256 amountOut_) external {
        amountOutToReturn = amountOut_;
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        lastFee = params.fee;
        amountOut = amountOutToReturn;
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
        return amountOut;
    }
}
