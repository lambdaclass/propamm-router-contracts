// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {AmountTooLarge} from "./Errors.sol";

/// @title UniV3Adapter
/// @notice Uniswap V3 integration helpers: derives core-pool addresses
/// (`computePool`), swaps an exact input directly against the core pool with no
/// periphery router or approval (`swapExactIn`), and prices swaps via
/// QuoterV2 (`quoteExactIn` / `quoteExactOut`). Single-hop; the caller picks the
/// fee tier.
/// @dev Quotes are non-view because QuoterV2 uses revert-based simulation;
/// call via `eth_call` (staticcall) from off-chain.
library UniV3Adapter {
    /// @notice Uniswap V3 mainnet factory and pool init-code hash, used by
    /// `computePool` to derive a core-pool address for direct (periphery-free) swaps.
    address internal constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    /// @notice `sqrtPriceLimitX96` sentinels imposing no price limit (full fill).
    /// The core pool rejects a literal 0: `TickMath.MIN_SQRT_RATIO + 1` for
    /// zero-for-one, `MAX_SQRT_RATIO - 1` otherwise.
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    /// @notice Derives the Uniswap V3 pool address for a token pair and fee tier.
    /// @dev Pure CREATE2 derivation from the canonical factory and init-code hash, so
    /// callers can use it both to locate the pool and to authenticate a swap callback
    /// (`msg.sender` must equal the derived address — only the real pool lives there).
    /// Order-independent: tokens are sorted to the pool's canonical `(token0, token1)`.
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token of the pair.
    /// @param fee The pool fee tier.
    function computePool(address tokenA, address tokenB, uint24 fee) internal pure returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", UNISWAP_V3_FACTORY, keccak256(abi.encode(token0, token1, fee)), POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    /// @notice Swaps an exact `amountIn` of `tokenIn` for `tokenOut` directly
    /// against the Uniswap V3 core pool, sending the output to `recipient`.
    /// @dev No periphery router and no approval: the derived pool calls back the
    /// CALLER's `uniswapV3SwapCallback` to collect `tokenIn` from `payer`, so the
    /// caller MUST implement that callback. Output is not returned — the caller
    /// measures it as a balance delta.
    ///
    /// WARNING: the `data` blob is a private ABI contract with the caller's
    /// `uniswapV3SwapCallback`. It encodes `(tokenIn, tokenOut, fee, payer)`, and the
    /// callback MUST `abi.decode` the identical tuple. The two halves live in
    /// different files (here and `PropAMMRouter.uniswapV3SwapCallback`) — change this
    /// encode and you MUST change that decode in lockstep, or payment/auth break.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param fee The pool fee tier identifying which pool to swap against.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param payer Account `tokenIn` is paid to the pool from: the router
    /// (`address(this)`) for wrapped ETH, otherwise the caller.
    function swapExactIn(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        address recipient,
        address payer
    ) internal {
        require(amountIn <= uint256(type(int256).max), AmountTooLarge());
        bool zeroForOne = tokenIn < tokenOut;
        IUniswapV3Pool(computePool(tokenIn, tokenOut, fee))
            .swap(
                recipient,
                zeroForOne,
                int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                abi.encode(tokenIn, tokenOut, fee, payer)
            );
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
    function quoteExactIn(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, address quoter)
        internal
        returns (uint256 amountOut)
    {
        (amountOut,,,) = IQuoterV2(quoter)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
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
    function quoteExactOut(address tokenIn, address tokenOut, uint24 fee, uint256 amountOut, address quoter)
        internal
        returns (uint256 amountIn)
    {
        (amountIn,,,) = IQuoterV2(quoter)
            .quoteExactOutputSingle(
                IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amount: amountOut, fee: fee, sqrtPriceLimitX96: 0
            })
            );
    }
}
