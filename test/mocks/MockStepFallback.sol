// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A SwapRouter02 + QuoterV2 stand-in whose unit rate is a step
/// function of the queried size, rather than a smooth, monotonically
/// decreasing curve like `MockConcaveUniswap`.
/// @dev Exists ONLY to test the `fallbackSwapRouter`-whitelisted-as-a-venue
/// misconfiguration (see `PropAMMRouter._gatherCandidates`'s `fallbackSwapRouter`
/// skip). With a well-behaved concave curve, the reference `_waterfall` cuts
/// candidates against is DERIVED FROM the exact same curve the fallback venue
/// is probed against, so it is provably impossible for a legitimate candidate
/// to rank below the fallback's own self-quote while still beating the
/// reference — the bug is real but economically inert against that shape of
/// curve. A real Uniswap V3 pool's price impact is NOT globally monotonic in
/// this idealized sense — concentrated liquidity leaves it size-dependent in
/// arbitrary ways across tick ranges — so this mock models that with an
/// explicit, arbitrary step schedule to make the misconfiguration's effect
/// (silently truncating a legitimate candidate ranked after the fallback)
/// observable in a test.
contract MockStepFallback {
    uint256 public t1 = 60e18;
    uint256 public t2 = 550e18;
    uint256 public t3 = 750e18;
    uint256 public r1Bps = 10_300; // amount <= t1
    uint256 public r2Bps = 9_000; // t1 < amount <= t2
    uint256 public r3Bps = 10_400; // t2 < amount <= t3
    uint256 public r4Bps = 10_200; // amount > t3

    function setThresholds(uint256 _t1, uint256 _t2, uint256 _t3) external {
        t1 = _t1;
        t2 = _t2;
        t3 = _t3;
    }

    function setRatesBps(uint256 _r1, uint256 _r2, uint256 _r3, uint256 _r4) external {
        r1Bps = _r1;
        r2Bps = _r2;
        r3Bps = _r3;
        r4Bps = _r4;
    }

    function _rateBps(uint256 amount) internal view returns (uint256) {
        if (amount <= t1) return r1Bps;
        if (amount <= t2) return r2Bps;
        if (amount <= t3) return r3Bps;
        return r4Bps;
    }

    function _out(uint256 amountIn) internal view returns (uint256) {
        return amountIn * _rateBps(amountIn) / 10_000;
    }

    // --- QuoterV2 surface ---------------------------------------------------

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory params)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        return (_out(params.amountIn), 0, 0, 0);
    }

    // --- SwapRouter02 surface -----------------------------------------------

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = _out(params.amountIn);
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}
