// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {IPropAMMFillable} from "../../src/interfaces/IPropAMMFillable.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A propAMM that advertises `IPropAMMFillable`. Every reported value
/// is settable so a test can drive an honest venue, an over-reporting venue,
/// or one that lies about supporting the interface.
contract MockFillablePropAMM is IPropAMM, IPropAMMFillable, IERC165 {
    uint256 public fillableToReturn;
    uint256 public outToReturn;
    uint256 public amountOutToDeliver;
    bool public supportsFillable = true;

    function setFillable(uint256 v) external {
        fillableToReturn = v;
    }

    function setOut(uint256 v) external {
        outToReturn = v;
    }

    function setAmountOut(uint256 v) external {
        amountOutToDeliver = v;
    }

    function setSupportsFillable(bool v) external {
        supportsFillable = v;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (interfaceId == type(IPropAMMFillable).interfaceId) return supportsFillable;
        return interfaceId == type(IERC165).interfaceId;
    }

    function quoteFillable(address, address, uint256) external view returns (uint256, uint256) {
        return (fillableToReturn, outToReturn);
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function swap(address, address tokenOut, uint256, uint256, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        amountOut = amountOutToDeliver;
        MockERC20(tokenOut).mint(recipient, amountOut);
        return amountOut;
    }
}
