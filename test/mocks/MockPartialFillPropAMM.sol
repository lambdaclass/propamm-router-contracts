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

    /// @notice When set, the venue reports `fillableAmountIn` inflated by this
    /// factor — violating the interface's "MUST be <= amountIn" requirement.
    /// The quoted `amountOut` matches the INFLATED fill, so a router that
    /// clamps the fill without rescaling the output reads a doubled rate.
    uint256 public overReportFactor;

    function setOverReportFactor(uint256 factor) external {
        overReportFactor = factor;
    }

    function quotePartialFill(address, address, uint256 amountIn)
        external
        view
        returns (uint256 fillableAmountIn, uint256 amountOut)
    {
        require(active, "inactive");
        fillableAmountIn = (cap != 0 && amountIn > cap) ? cap : amountIn;
        if (overReportFactor > 1) fillableAmountIn = fillableAmountIn * overReportFactor;
        amountOut = fillableAmountIn * priceDen / priceNum;
    }
}
