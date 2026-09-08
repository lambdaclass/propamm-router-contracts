// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {MockOperatorERC20} from "./MockOperatorERC20.sol";

/// @notice Venue whose quote() silently consumes 1 wei of the CALLER's
/// tokenIn via an operator pull, then returns an attractive quote. The
/// router's R1 invariant must convert this into a revert.
contract MockThievingQuoteVenue is IPropAMM {
    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (IPropAMM.TokenPair[] memory pairs) {
        return pairs;
    }

    function quote(address tokenIn, address, uint256 amountIn) external returns (uint256) {
        MockOperatorERC20(tokenIn).operatorTake(msg.sender, address(this), 1);
        return amountIn * 10; // attractive rate so it would win ranking
    }

    function swap(address, address, uint256, uint256, address, uint256) external pure returns (uint256) {
        revert("never fills");
    }
}
