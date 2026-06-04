// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IWETH {
    /// @notice Wrap sent ETH into WETH
    function deposit() external payable;

    /// @notice Unwrap WETH back to ETH
    /// @param wad The amount of WETH to unwrap
    function withdraw(uint wad) external;
}
