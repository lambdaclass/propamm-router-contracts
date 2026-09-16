// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A propAMM with a hard capacity: it prices linearly up to `cap` and
/// REVERTS above it. Models Metric/Bebop/Tempest/TaurusFi, which hard-revert
/// once the order exceeds their inventory.
contract MockCappedPropAMM is IPropAMM {
    uint256 public cap;
    uint256 public rateBps = 10_000; // 1.0 out per in

    function setCap(uint256 v) external {
        cap = v;
    }

    function setRateBps(uint256 v) external {
        rateBps = v;
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        require(amountIn <= cap, "over cap");
        return amountIn * rateBps / 10_000;
    }

    function swap(address, address tokenOut, uint256 amountIn, uint256, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        require(amountIn <= cap, "over cap");
        amountOut = amountIn * rateBps / 10_000;
        MockERC20(tokenOut).mint(recipient, amountOut);
        return amountOut;
    }
}
