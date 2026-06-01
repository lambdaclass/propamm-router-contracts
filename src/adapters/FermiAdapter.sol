// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPropAMM} from "../interfaces/IPropAMM.sol";
import {IFermiSwapper} from "../interfaces/IFermiSwapper.sol";

/// @title FermiAdapter
/// @notice Wraps FermiSwap behind `IPropAMM` so `PropAMMRouter` can route to it
/// through the uniform whitelist.
/// @dev Holds no funds between swaps. The router pushes `tokenIn` here before
/// calling `swap`; FermiSwap then pulls it via allowance.
contract FermiAdapter is IPropAMM {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The FermiSwap router this adapter wraps.
    address public immutable fermiRouter;

    /// @notice Thrown when constructed with the zero address.
    error ZeroAddress();

    constructor(address fermiRouter_) {
        require(fermiRouter_ != address(0), ZeroAddress());
        fermiRouter = fermiRouter_;
    }

    /// @inheritdoc IPropAMM
    /// @dev Conservatively reports active; real liveness is enforced by `quote`
    /// and `swap` reverting. FermiSwap exposes no per-pair liveness view.
    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IPropAMM
    /// @dev FermiSwap does not enumerate pairs; returns empty.
    function getPairs() external pure returns (Pair[] memory pairs) {
        return pairs;
    }

    /// @inheritdoc IPropAMM
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut) {
        (, amountOut) = IFermiSwapper(fermiRouter).quoteAmounts(tokenIn, tokenOut, amountIn.toInt256());
    }

    /// @inheritdoc IPropAMM
    /// @dev Approves FermiSwap to pull the pushed `amountIn`, swaps with
    /// `minAmountOut` as Fermi's `amountCheck` (Fermi reverts on an under-fill),
    /// and resets the approval to 0.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
    {
        IERC20(tokenIn).forceApprove(fermiRouter, amountIn);
        IFermiSwapper(fermiRouter)
            .fermiSwapWithAllowances(tokenIn, tokenOut, amountIn.toInt256(), minAmountOut, recipient);
        IERC20(tokenIn).forceApprove(fermiRouter, 0);
    }
}
