// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

contract MockQuoterV2 {
    uint256 public quoteToReturn;

    function setQuote(uint256 quote) external {
        quoteToReturn = quote;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        return (quoteToReturn, 0, 0, 0);
    }
}
