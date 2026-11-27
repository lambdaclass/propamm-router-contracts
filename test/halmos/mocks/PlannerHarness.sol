// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PropAMMRouter} from "../../../src/PropAMMRouter.sol";
import {SplitPlanner} from "../../../src/libraries/SplitPlanner.sol";

/// @notice Exposes the router's REAL planning and execution code to the Halmos
/// checks, with nothing overridden: candidates go straight into `_waterfall`
/// (and `SplitPlanner`) instead of being probed from live venues, and a plan
/// goes straight into `_executeLegs`. The Uniswap reference quotes still go
/// through `_tryQuote` to the configured quoter.
/// @dev Test-only. Deployed behind an `ERC1967Proxy` like the router itself.
contract PlannerHarness is PropAMMRouter {
    function waterfall(SplitPlanner.Candidate[] memory cands, address tokenIn_, address tokenOut_, uint256 amountIn)
        external
        returns (Leg[] memory)
    {
        return _waterfall(cands, tokenIn_, tokenOut_, amountIn);
    }

    function executeLegs(Leg[] memory legs, LegRun memory r) external returns (uint256) {
        return _executeLegs(legs, r);
    }

    function sortByRateDesc(SplitPlanner.Candidate[] memory cands)
        external
        pure
        returns (SplitPlanner.Candidate[] memory)
    {
        SplitPlanner.sortByRateDesc(cands);
        return cands;
    }
}
