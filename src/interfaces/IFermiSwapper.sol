// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the FermiSwap router used for FermiSwap-routed swaps.
address constant FERMI_ROUTER = 0x5979458912F80B96d30D4220af8E2e4925A33320;

interface IFermiSwapper {
    function fermiSwapWithAllowances(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient
    ) external returns (uint256, uint256);

    function quoteAmounts(address tokenIn, address tokenOut, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut);
}
