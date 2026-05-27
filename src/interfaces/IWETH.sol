// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

interface IWETH {
    /// @notice Wrap sent ETH into WETH
    function deposit() external payable;

    /// @notice Unwrap WETH back to ETH
    /// @param wad The amount of WETH to unwrap
    function withdraw(uint wad) external;
}
