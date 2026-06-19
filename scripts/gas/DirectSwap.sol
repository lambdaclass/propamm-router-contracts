// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Minimal "direct integrator": push tokenIn to the PropAMM, then swap.
// Injected via state-override `code`; takes everything from calldata so no
// constructor/storage init is needed.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPropAMM {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256);
}

contract DirectSwap {
    function run(
        address tokenIn,
        address venue,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256) {
        IERC20(tokenIn).transfer(venue, amountIn); // push-payment
        return IPropAMM(venue).swap(tokenIn, tokenOut, amountIn, minOut, recipient, deadline);
    }
}
