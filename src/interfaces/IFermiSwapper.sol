// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the FermiSwap router used for FermiSwap-routed swaps.
address constant FERMI_ROUTER = 0xb1076fE3AB5e28005C7c323Bac5AC06a680d452e;

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
