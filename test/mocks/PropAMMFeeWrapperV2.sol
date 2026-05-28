// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PropAMMFeeWrapper} from "../../src/PropAMMFeeWrapper.sol";

/// @notice Minimal upgrade target to prove UUPS upgrade preserves storage.
/// @custom:oz-upgrades-from PropAMMFeeWrapper
contract PropAMMFeeWrapperV2 is PropAMMFeeWrapper {
    function version() external pure returns (uint256) {
        return 2;
    }
}
