// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMM
/// @notice Interface PropAMMs must implement to be compatible with the PropAMMRouter.
interface IPropAMM {
    /// @notice Quote `amountIn` of `tokenIn` and returns the amount of
    /// `tokenOut` to receive. This function must:
    ///     - Revert if inactive (i.e., if a swap would revert in current conditions).
    ///     - Not require `tokenIn` balance from the sender.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to quote against.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (uint256 amountOut);

    /// @notice Returns if the PropAMM is active, i.e., if a swap would
    /// succeed in current conditions
    function isActive() external view returns (bool);

    /// @notice Swaps an exact amount of `tokenIn` for as much `tokenOut` as
    /// possible.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param minAmountOut The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external;
}
