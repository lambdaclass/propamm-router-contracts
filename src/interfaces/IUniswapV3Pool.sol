// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IUniswapV3Pool
/// @notice Minimal Uniswap V3 core-pool surface the router swaps against directly.
/// @dev Only `swap` is needed; the pool pays out optimistically and then calls
/// `uniswapV3SwapCallback` on `msg.sender` to collect the input.
interface IUniswapV3Pool {
    /// @notice Swap `tokenIn` for `tokenOut`.
    /// @param recipient The address that receives the output token.
    /// @param zeroForOne True if swapping token0 for token1 (i.e. `tokenIn < tokenOut`).
    /// @param amountSpecified Exact input when positive, exact output when negative.
    /// @param sqrtPriceLimitX96 Price limit; pass the just-inside-bounds sentinel for no limit.
    /// @param data Opaque bytes forwarded verbatim to `uniswapV3SwapCallback`.
    /// @return amount0 The token0 delta for the pool (positive = pool received).
    /// @return amount1 The token1 delta for the pool (positive = pool received).
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
