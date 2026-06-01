// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the Kipseli quoter used to price Kipseli-routed swaps.
address constant KIPSELI_QUOTER = 0x054F0377e07d2F460151F935Dffc4D880017E63a;

interface IKipseliQuoter {
    function preSwapQuote(address tokenIn, uint256 amountIn, address tokenOut, uint256 quoteTimestamp, address dest)
        external
        returns (uint256 amountOut);
}
