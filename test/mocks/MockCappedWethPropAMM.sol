// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";

/// @notice `MockCappedPropAMM`, but delivers `tokenOut` via `safeTransfer` from
/// pre-funded liquidity (like `MockPropAMMExactOut`) instead of `MockERC20.mint`.
/// @dev `MockCappedPropAMM` and `MockFillablePropAMM` both deliver by minting
/// `tokenOut`, which reverts against `MockWETH` (no such selector) — this mock
/// is the hard-capacity (reverts above `cap`) venue an ETH-out test can use.
contract MockCappedWethPropAMM is IPropAMM {
    using SafeERC20 for IERC20;

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
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }
}
