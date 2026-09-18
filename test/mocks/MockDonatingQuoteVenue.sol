// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A venue that CREDITS the router mid-quote. R1 is directional, so
/// this must be TOLERATED — an exact-equality check would let any single
/// whitelisted venue brick every caller's split for the price of one wei, and
/// would break on a rebasing or reflection token.
contract MockDonatingQuoteVenue is IPropAMM {
    address public router;
    address public token;
    uint256 public donateAmount;

    function configure(address router_, address token_, uint256 amount_) external {
        router = router_;
        token = token_;
        donateAmount = amount_;
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256) external returns (uint256) {
        MockERC20(token).mint(router, donateAmount);
        return 0; // not a candidate; the donation is the point
    }

    function swap(address, address, uint256, uint256, address, uint256) external pure returns (uint256) {
        revert("not used");
    }
}
