// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @notice Minimal QuoterV2 stand-in. Records the fee tier it was called with
/// and returns a configurable amountOut.
contract MockQuoterV2 {
    uint24 public lastFee;
    uint256 public amountOutToReturn; // defaults to 0; call setAmountOut(...) before swap/quote tests

    function setAmountOut(uint256 amountOut_) external {
        amountOutToReturn = amountOut_;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        lastFee = params.fee;
        return (amountOutToReturn, 0, 0, 0);
    }
}
