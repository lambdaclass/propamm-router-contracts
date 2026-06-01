// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @notice Minimal QuoterV2 stand-in. Records the fee tier it was called with
/// and returns a configurable amountOut. Exposes both `setQuote` and
/// `setAmountOut` (same backing field) so both fee test suites compile.
contract MockQuoterV2 {
    uint24 public lastFee;
    uint256 public amountOutToReturn; // defaults to 0; set before swap/quote tests

    function setQuote(uint256 quote) external {
        amountOutToReturn = quote;
    }

    function setAmountOut(uint256 amountOut_) external {
        amountOutToReturn = amountOut_;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        lastFee = params.fee;
        return (amountOutToReturn, 0, 0, 0);
    }
}
