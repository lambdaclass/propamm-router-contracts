// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Constant-product pricing shared by the concave router/quoter pair:
/// `out = reserveOut * in / (reserveIn + in)`. Unlike {MockLinearSwapRouter}'s
/// flat rate, the UNIT rate here strictly decreases with size — which is the
/// only condition under which `_waterfall`'s one-shot reference refinement can
/// change an outcome.
///
/// Why the linear mock cannot cover that branch: the cutoff test is
/// `out * refSize <= refOut * fill`. With a flat rate `refOut = refSize * d/n`,
/// so `refSize` cancels and the predicate collapses to `out/fill <= d/n` —
/// independent of the reference SIZE. A candidate contested at the coarse
/// `amountIn/100` reference is therefore contested at the refined reference
/// too, and the refinement always falls through to its `break`. The branch
/// where refinement RESCUES a candidate is unreachable. Concave pricing makes
/// the coarse reference overstate Uniswap (small size ⇒ good rate), so it
/// wrongly contests a genuinely-better prop venue that the refined reference
/// at the true residual then admits.
library ConcaveMath {
    function amountOut(uint256 reserveIn, uint256 reserveOut, uint256 amountIn) internal pure returns (uint256) {
        if (amountIn == 0) return 0;
        return reserveOut * amountIn / (reserveIn + amountIn);
    }
}

/// @notice Constant-product SwapRouter02 stand-in: pulls tokenIn, mints
/// tokenOut along the curve. Reserves are virtual (nothing is held).
contract MockConcaveSwapRouter {
    uint256 public reserveIn = 1_000_000e18;
    uint256 public reserveOut = 1_000_000e18;

    function setReserves(uint256 rIn, uint256 rOut) external {
        reserveIn = rIn;
        reserveOut = rOut;
    }

    function quote(uint256 amountIn) public view returns (uint256) {
        return ConcaveMath.amountOut(reserveIn, reserveOut, amountIn);
    }

    function exactInputSingle(IV3SwapRouter.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = quote(params.amountIn);
        require(amountOut >= params.amountOutMinimum, "uni-slippage");
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}

/// @notice Constant-product QuoterV2 stand-in matching {MockConcaveSwapRouter}.
/// Reserves are set independently so a test can make the quoter and the router
/// disagree (e.g. to model a sandwich landing between quote and execution).
contract MockConcaveQuoterV2 {
    uint256 public reserveIn = 1_000_000e18;
    uint256 public reserveOut = 1_000_000e18;

    function setReserves(uint256 rIn, uint256 rOut) external {
        reserveIn = rIn;
        reserveOut = rOut;
    }

    function quote(uint256 amountIn) public view returns (uint256) {
        return ConcaveMath.amountOut(reserveIn, reserveOut, amountIn);
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata params)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        return (quote(params.amountIn), 0, 0, 0);
    }
}
