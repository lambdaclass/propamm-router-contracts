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
    /// @notice Fraction of `quote`'s own output that `swap` actually delivers,
    /// in bps. Defaults to 10_000 (delivers exactly what it quoted). Set below
    /// 10_000 to model a venue whose fill undershoots its own quote — the only
    /// way to test `_executeLegs`'s absorption path against a venue that still
    /// prices linearly (and so wins a leg through the ordinary, non-degenerate
    /// probe) rather than one whose quote is flat and never wins a leg at all.
    uint256 public deliveryBps = 10_000;

    function setCap(uint256 v) external {
        cap = v;
    }

    function setRateBps(uint256 v) external {
        rateBps = v;
    }

    function setDeliveryBps(uint256 v) external {
        deliveryBps = v;
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
        uint256 quoted = amountIn * rateBps / 10_000;
        amountOut = quoted * deliveryBps / 10_000;
        MockERC20(tokenOut).mint(recipient, amountOut);
        return amountOut;
    }
}
