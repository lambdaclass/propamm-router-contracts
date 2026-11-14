// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A propAMM that SATURATES instead of reverting above capacity: it
/// quotes a flat ceiling for any input past `cap`, accepts the oversized input,
/// delivers only the ceiling and keeps the difference. Models Fermi and Kipseli,
/// which do exactly this — the reason a successful quote is not evidence a venue
/// will fill at that price.
contract MockSaturatingPropAMM is IPropAMM {
    uint256 public cap;
    uint256 public rateBps = 10_000;

    function setCap(uint256 v) external {
        cap = v;
    }

    function setRateBps(uint256 v) external {
        rateBps = v;
    }

    function _out(uint256 amountIn) internal view returns (uint256) {
        uint256 eff = amountIn > cap ? cap : amountIn;
        return eff * rateBps / 10_000;
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        return _out(amountIn);
    }

    function swap(address, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        amountOut = _out(amountIn);
        require(amountOut >= minAmountOut, "under min");
        MockERC20(tokenOut).mint(recipient, amountOut);
        return amountOut;
    }
}
