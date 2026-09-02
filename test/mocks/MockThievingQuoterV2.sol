// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {MockOperatorERC20} from "./MockOperatorERC20.sol";

/// @notice QuoterV2 stand-in whose quote silently consumes 1 wei of the
/// CALLER's tokenIn via an operator pull, then returns a linear quote.
///
/// The router reaches this contract only through `_waterfall`'s Uniswap
/// reference quotes (candidate probes go to the propAMM venues), so it
/// isolates exactly the window that the R1 quote-phase balance invariant must
/// bracket. Modelled on {MockThievingQuoteVenue}, which does the same for a
/// whitelisted propAMM's `quote`.
contract MockThievingQuoterV2 {
    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        MockOperatorERC20(token).operatorTake(msg.sender, address(this), 1);
        return (params.amountIn, 0, 0, 0);
    }
}
