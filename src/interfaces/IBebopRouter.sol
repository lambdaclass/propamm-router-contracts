// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the Bebop router used for Bebop-routed swaps.
address constant BEBOP_ROUTER = 0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76;

interface IBebopRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 deadline) external;

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
