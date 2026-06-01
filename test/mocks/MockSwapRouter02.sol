// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal SwapRouter02 stand-in. Records the fee tier it was called
/// with and delivers a configurable amountOut of tokenOut to the recipient.
contract MockSwapRouter02 {
    uint24 public lastFee;
    uint256 public amountOutToReturn; // defaults to 0; call setAmountOut(...) before swap/quote tests

    function setAmountOut(uint256 amountOut_) external {
        amountOutToReturn = amountOut_;
    }

    /// @dev Deliberate deviation from the real SwapRouter02: this mock does NOT
    /// pull `tokenIn` from the caller; it only delivers `tokenOut`. As a result
    /// the router retains the `tokenIn` it pulled after a swap in tests. That is
    /// intentional for these fee-wiring tests and does not affect the recipient
    /// balance-delta assertions (which measure `tokenOut` delivered).
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
