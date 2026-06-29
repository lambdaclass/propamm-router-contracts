// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {MockUniV3Pool} from "../mocks/MockUniV3Pool.sol";
import {UniV3Router} from "../../src/libraries/UniV3Router.sol";

/// @notice Test fixture for the router's direct core-pool fallback. The router
/// derives the pool address from `(token0, token1, fee)` and swaps against it, so
/// tests `vm.etch` a `MockUniV3Pool` at that exact address. Deriving the address
/// with the same factory + init-code hash the router uses keeps them in lockstep,
/// and seeding the pool *only* at the expected fee tier turns a successful swap
/// into proof that tier was used (a wrong fee resolves to a code-less address that
/// reverts).
abstract contract UniV3PoolFixture is Test {
    /// @dev Etch a `MockUniV3Pool` at the router-derived address for the pair/fee
    /// and arm it to deliver `amountOut`. Returns the address so the caller can
    /// fund it with `tokenOut` liquidity.
    function _seedUniV3Pool(address tokenIn, address tokenOut, uint24 fee, uint256 amountOut)
        internal
        returns (address pool)
    {
        pool = UniV3Router.computePool(tokenIn, tokenOut, fee);
        if (pool.code.length == 0) {
            vm.etch(pool, type(MockUniV3Pool).runtimeCode);
        }
        MockUniV3Pool(pool).setAmountOut(amountOut);
    }
}
