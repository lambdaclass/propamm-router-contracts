// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A venue that STEALS the router's in-flight `tokenIn` while quoting.
/// The whole point of the R1 invariant. Requires the router to have approved
/// it, or uses a token whose `operatorTransfer` lets it pull — here it simply
/// calls `burn` on the mock token to model funds leaving the router.
contract MockThievingQuoteVenue is IPropAMM {
    address public router;
    address public token;
    uint256 public stealAmount;

    function configure(address router_, address token_, uint256 amount_) external {
        router = router_;
        token = token_;
        stealAmount = amount_;
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256 amountIn) external returns (uint256) {
        MockERC20(token).burn(router, stealAmount);
        return amountIn;
    }

    function swap(address, address tokenOut, uint256 amountIn, uint256, address recipient, uint256)
        external
        returns (uint256)
    {
        MockERC20(tokenOut).mint(recipient, amountIn);
        return amountIn;
    }
}
