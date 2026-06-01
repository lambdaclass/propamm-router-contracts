// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMM
/// @notice Interface a proprietary AMM (or a thin adapter wrapping one) must
/// implement to be added to the `PropAMMRouter` whitelist. The router speaks
/// ONLY this interface to whitelisted venues, so every venue-specific quirk
/// lives behind an implementation of `IPropAMM` rather than in the router.
/// @dev The router uses a push-payment model: before calling `swap` it
/// transfers `amountIn` of `tokenIn` to the venue, then `swap` is expected to
/// consume that balance. This mirrors how the router already wraps the call in
/// a self-call `try/catch`, so a reverting `swap` rolls back the transfer and
/// the router's Uniswap fallback engages.
interface IPropAMM {
    /// @notice A token pair a venue supports.
    struct Pair {
        address token0;
        address token1;
    }

    /// @notice Returns true if the venue can swap `tokenIn` for `tokenOut` in
    /// the current block.
    /// @dev A `view` fast-path the router can use to skip dead venues before
    /// paying for a state-changing `quote`. It is advisory: `quote`/`swap` are
    /// still the source of truth and must revert when a swap would actually
    /// fail. Reported per-pair so a venue can be live for some pairs and not
    /// others.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @return active True if a swap for the pair would succeed right now.
    function isActive(address tokenIn, address tokenOut) external view returns (bool active);

    /// @notice Returns every token pair the venue currently has pools for.
    /// @dev Advisory, for off-chain discovery; the router does not call this on
    /// its swap path.
    /// @return pairs The supported pairs.
    function getPairs() external view returns (Pair[] memory pairs);

    /// @notice Quotes `amountIn` of `tokenIn` and returns the `tokenOut` amount
    /// a swap would deliver.
    /// @dev Must revert if the venue is inactive for the pair (i.e. if a swap
    /// would revert under current conditions). Must NOT require a `tokenIn`
    /// balance or allowance from the caller — it only prices. Not `view`:
    /// pricing may touch state (e.g. an external quoter that mutates).
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` the swap would deliver.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut);

    /// @notice Swaps an exact `amountIn` of `tokenIn` for as much `tokenOut` as
    /// possible, delivering it to `recipient`.
    /// @dev Expects `amountIn` of `tokenIn` to have ALREADY been transferred to
    /// the venue by the caller (push-payment). Must revert if it cannot deliver
    /// at least `minAmountOut` of `tokenOut` to `recipient`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param minAmountOut The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient) external;
}
