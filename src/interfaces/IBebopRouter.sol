// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the Bebop router used for Bebop-routed swaps.
address constant BEBOP_ROUTER = 0xdB13ad0fcD134E9c48f2fDaEa8f6751a0F5349ca;

interface IBebopRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 deadline) external;

    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
