// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {IPropAMMPartialFill} from "../../src/interfaces/IPropAMMPartialFill.sol";
import {MockCappedPropAMM} from "./MockCappedPropAMM.sol";

contract MockPartialFillPropAMM is MockCappedPropAMM {
    constructor(uint256 priceNum_, uint256 priceDen_) MockCappedPropAMM(priceNum_, priceDen_) {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IPropAMM).interfaceId
            || interfaceId == type(IPropAMMPartialFill).interfaceId;
    }

    function quotePartialFill(address, address, uint256 amountIn)
        external
        view
        returns (uint256 fillableAmountIn, uint256 amountOut)
    {
        require(active, "inactive");
        fillableAmountIn = (cap != 0 && amountIn > cap) ? cap : amountIn;
        amountOut = fillableAmountIn * priceDen / priceNum;
    }
}
