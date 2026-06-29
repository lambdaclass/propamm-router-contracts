// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Minimal Uniswap V3 core-pool stand-in for unit tests. `vm.etch` it at
/// the address `PropAMMRouter._computePool` derives for a `(token0, token1, fee)`
/// triple (see `UniV3PoolFixture`), fund it with `tokenOut`, and `setAmountOut`
/// the amount to deliver. Mirrors the real pool's flash accounting: pay the
/// output out first, then call the caller back for the input and assert it landed.
contract MockUniV3Pool {
    uint256 public amountOut;
    uint256 public extraInputOwed;

    function setAmountOut(uint256 amountOut_) external {
        amountOut = amountOut_;
    }

    /// @dev Make the pool demand `amountSpecified + extra` of `tokenIn`, to exercise
    /// the router's `ExcessiveInput` guard. Defaults to 0 (a well-behaved pool).
    function setExtraInputOwed(uint256 extra) external {
        extraInputOwed = extra;
    }

    /// @dev Exact-input only: `amountSpecified` is the positive `tokenIn` amount.
    /// Reads `tokenIn`/`tokenOut` from the router-supplied callback `data`.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 owed = uint256(amountSpecified) + extraInputOwed;
        (address tokenIn, address tokenOut,,) = abi.decode(data, (address, address, uint24, address));

        // Deliver output optimistically, then collect input via the callback.
        IERC20(tokenOut).transfer(recipient, amountOut);
        (amount0, amount1) = zeroForOne ? (int256(owed), -int256(amountOut)) : (-int256(amountOut), int256(owed));

        uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= balanceBefore + owed, "IIA");
    }
}
