// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the Bebop router used for Bebop-routed swaps.
address constant BEBOP_ROUTER = 0x160141A205F5dDcf096BA3F48B7eD21EB52c62EA;

interface IBebopRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 deadline) external;

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
