// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// Address of the Kipseli router used for Kipseli-routed swaps.
address constant KIPSELI_PAMM = 0x5CDbE59400Cc2EFDCC2B54acca4a99FE00dD588c;

interface IKipseliPAMM {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, address recipient) external returns (uint256);
}
