// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPropAMM} from "../interfaces/IPropAMM.sol";
import {IBebopRouter} from "../interfaces/IBebopRouter.sol";

/// @title BebopAdapter
/// @notice Wraps the Bebop router behind `IPropAMM` so `PropAMMRouter` can route
/// to it through the uniform whitelist.
/// @dev Holds no funds between swaps. Bebop has no recipient argument — it pays
/// `msg.sender` (this adapter), which then forwards `tokenOut` to `recipient`.
contract BebopAdapter is IPropAMM {
    using SafeERC20 for IERC20;

    /// @notice The Bebop router this adapter wraps.
    address public immutable bebopRouter;

    /// @notice Thrown when constructed with the zero address.
    error ZeroAddress();
    /// @notice Thrown when Bebop delivers below `minAmountOut`, so the router's
    /// fallback engages.
    error InsufficientOutput();

    constructor(address bebopRouter_) {
        require(bebopRouter_ != address(0), ZeroAddress());
        bebopRouter = bebopRouter_;
    }

    /// @inheritdoc IPropAMM
    /// @dev Conservatively reports active; real liveness is enforced by `quote`
    /// and `swap` reverting. Bebop exposes no per-pair liveness view.
    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IPropAMM
    /// @dev Bebop does not enumerate pairs; returns empty.
    function getPairs() external pure returns (Pair[] memory pairs) {
        return pairs;
    }

    /// @inheritdoc IPropAMM
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        amountOut = IBebopRouter(bebopRouter).quote(tokenIn, tokenOut, amountIn);
    }

    /// @inheritdoc IPropAMM
    /// @dev Approves Bebop to pull the pushed `amountIn`, swaps (passing the
    /// current timestamp as the deadline — the router already enforced the
    /// user's deadline), resets the approval, then forwards the received
    /// `tokenOut` to `recipient`. Reverts `InsufficientOutput` on an under-fill.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
    {
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(bebopRouter, amountIn);
        IBebopRouter(bebopRouter).swap(tokenIn, tokenOut, amountIn, minAmountOut, block.timestamp);
        IERC20(tokenIn).forceApprove(bebopRouter, 0);

        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        require(received >= minAmountOut, InsufficientOutput());
        if (received > 0 && recipient != address(this)) {
            IERC20(tokenOut).safeTransfer(recipient, received);
        }
    }
}
