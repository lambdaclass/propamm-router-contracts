// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";

/// @notice Configurable `IPropAMM` test double.
/// @dev `swap` delivers `swapOutput` of `tokenOut` from this contract's own
/// balance, so tests must pre-fund it. Knobs let a single venue model the
/// scenarios the router must handle: a normal fill, an under-fill (quote high /
/// deliver low) that the router's balance-delta check must catch, an inactive
/// venue, and a hard revert that must trigger the fallback.
contract MockPropAMM is IPropAMM {
    uint256 public quoteAmount; // what `quote` returns
    uint256 public swapOutput; // what `swap` actually delivers (defaults to quoteAmount)
    bool public active = true;
    bool public revertOnSwap;

    constructor(uint256 quoteAmount_) {
        quoteAmount = quoteAmount_;
        swapOutput = quoteAmount_;
    }

    function setQuote(uint256 q) external {
        quoteAmount = q;
    }

    function setSwapOutput(uint256 s) external {
        swapOutput = s;
    }

    function setActive(bool a) external {
        active = a;
    }

    function setRevertOnSwap(bool r) external {
        revertOnSwap = r;
    }

    /// @inheritdoc IPropAMM
    function isActive(address, address) external view returns (bool) {
        return active;
    }

    /// @inheritdoc IPropAMM
    function getPairs() external pure returns (Pair[] memory pairs) {
        return pairs; // empty
    }

    /// @inheritdoc IPropAMM
    function quote(address, address, uint256) external view returns (uint256) {
        require(active, "MockPropAMM: inactive");
        return quoteAmount;
    }

    /// @inheritdoc IPropAMM
    function swap(address, address tokenOut, uint256, uint256 minAmountOut, address recipient) external {
        require(!revertOnSwap, "MockPropAMM: swap reverted");
        require(swapOutput >= minAmountOut, "MockPropAMM: insufficient output");
        IERC20(tokenOut).transfer(recipient, swapOutput);
    }
}
