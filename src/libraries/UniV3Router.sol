// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";

/// @title UniV3Router
/// @notice Thin wrapper around Uniswap V3's SwapRouter02 + QuoterV2.
/// Single-hop only. The caller picks the fee tier (pool selection
/// is the caller's job — this library does no routing).
/// @dev Quotes are non-view because QuoterV2 uses revert-based simulation;
/// call via `eth_call` (staticcall) from off-chain.
library UniV3Router {
    using SafeERC20 for IERC20;

    /// @notice Swaps an exact amount of `tokenIn` for `tokenOut` via Uniswap V3.
    /// @dev Assumes the caller has already transferred `amountIn` of `tokenIn`
    /// to `address(this)`. Approves `swapRouter` for `amountIn`, executes the
    /// single-hop swap, and unconditionally resets the approval to 0 after.
    /// Reverts if the resulting output is below `amountOutMinimum`; no
    /// slippage check beyond that is performed.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param fee The Uniswap V3 pool fee tier (in hundredths of a bip).
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMinimum The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param swapRouter The address of the Uniswap V3 SwapRouter02 contract.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        address swapRouter
    ) internal returns (uint256 amountOut) {
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        amountOut = IV3SwapRouter(swapRouter).exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );

        // Prevent later transfers if token was partially pulled
        IERC20(tokenIn).forceApprove(swapRouter, 0);
    }

    /// @notice Swaps as little `tokenIn` as needed to receive an exact `amountOut`
    /// of `tokenOut` via Uniswap V3.
    /// @dev Assumes the caller has already transferred `amountInMaximum` of
    /// `tokenIn` to `address(this)`. Approves `swapRouter` for the full
    /// `amountInMaximum`, executes the swap, unconditionally resets the
    /// approval to 0, and refunds any unspent portion to `msg.sender`.
    /// Reverts if the required input would exceed `amountInMaximum`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param fee The Uniswap V3 pool fee tier (in hundredths of a bip).
    /// @param amountOut The exact amount of `tokenOut` to receive.
    /// @param amountInMaximum The maximum amount of `tokenIn` the caller is willing
    /// to spend.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param swapRouter The address of the Uniswap V3 SwapRouter02 contract.
    /// @return amountIn The amount of `tokenIn` actually spent on the swap.
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint256 amountInMaximum,
        address recipient,
        address swapRouter
    ) internal returns (uint256 amountIn) {
        IERC20(tokenIn).forceApprove(address(swapRouter), amountInMaximum);

        amountIn = IV3SwapRouter(swapRouter).exactOutputSingle(
            IV3SwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: recipient,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(tokenIn).forceApprove(address(swapRouter), 0);

        if (amountIn < amountInMaximum) {
            IERC20(tokenIn).safeTransfer(
                msg.sender,
                amountInMaximum - amountIn
            );
        }
    }

    /// @notice Quotes the `tokenOut` received for selling an exact `amountIn`
    /// of `tokenIn` through the given Uniswap V3 pool.
    /// @dev Not `view`: QuoterV2 simulates the swap via a revert. Call this
    /// off-chain through `eth_call` / `staticcall`; calling it on-chain wastes
    /// gas and exposes the caller to MEV.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param fee The Uniswap V3 pool fee tier (in hundredths of a bip).
    /// @param amountIn The exact amount of `tokenIn` to quote against.
    /// @param quoter The address of the Uniswap V3 QuoterV2 contract.
    /// @return amountOut The amount of `tokenOut` the swap would produce.
    function quoteExactIn(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        address quoter
    ) internal returns (uint256 amountOut) {
        (amountOut, , , ) = IQuoterV2(quoter).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @notice Quotes the `tokenIn` required to receive an exact `amountOut`
    /// of `tokenOut` through the given Uniswap V3 pool.
    /// @dev Not `view`: QuoterV2 simulates the swap via a revert. Call this
    /// off-chain through `eth_call` / `staticcall`; calling it on-chain wastes
    /// gas and exposes the caller to MEV.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param fee The Uniswap V3 pool fee tier (in hundredths of a bip).
    /// @param amountOut The exact amount of `tokenOut` to quote against.
    /// @param quoter The address of the Uniswap V3 QuoterV2 contract.
    /// @return amountIn The amount of `tokenIn` the swap would require.
    function quoteExactOut(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        address quoter
    ) internal returns (uint256 amountIn) {
        (amountIn, , , ) = IQuoterV2(quoter).quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amount: amountOut,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
