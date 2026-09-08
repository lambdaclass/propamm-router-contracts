// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal generic propAMM stand-in speaking the `IPropAMM` interface.
/// @dev The quote and the delivered amount are configured separately so a test
/// can drive a venue that quotes one number and fills another — the only way to
/// exercise the router's venue *selection* independently of its execution-time
/// output check.
contract MockPropAMM is IPropAMM {
    uint256 public quoteToReturn;
    uint256 public amountOutToDeliver;

    function setQuote(uint256 quote_) external {
        quoteToReturn = quote_;
    }

    function setAmountOut(uint256 amountOut_) external {
        amountOutToDeliver = amountOut_;
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory pairs) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256) external view returns (uint256) {
        return quoteToReturn;
    }

    /// @dev Push-payment model: the router has already transferred `tokenIn`
    /// here, which this mock simply keeps. Mirrors `MockSwapRouter02` in only
    /// delivering `tokenOut`.
    function swap(address, address tokenOut, uint256, uint256, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        amountOut = amountOutToDeliver;
        MockERC20(tokenOut).mint(recipient, amountOut);
        return amountOut;
    }
}
