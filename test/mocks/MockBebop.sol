// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockBebop {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, uint256) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, IERC20(tokenOut).balanceOf(address(this)));
    }
}
