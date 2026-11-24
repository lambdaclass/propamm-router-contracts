// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMMFillable} from "../../../src/interfaces/IPropAMMFillable.sol";
import {SymVenue} from "./SymVenue.sol";

/// @notice `SymVenue` that also advertises `IPropAMMFillable`, so the router
/// prices it through `quoteFillable` (one call) instead of the blind probe.
/// @dev `quoteFillable` returns a fresh symbolic `(fillableAmountIn,
/// amountOut)` — possibly over-reporting, zero or absurd — and records it as a
/// quote `(fill -> out)`, the same pair the router turns into a candidate. The
/// check's witness search reads these records exactly like `quote`'s.
contract SymFillableVenue is SymVenue, IERC165 {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC165).interfaceId || id == type(IPropAMMFillable).interfaceId;
    }

    function quoteFillable(address, address, uint256) external returns (uint256 fillableAmountIn, uint256 amountOut) {
        fillableAmountIn = svm.createUint256("venue.fillable");
        amountOut = svm.createUint256("venue.fillableOut");
        quoteSizes.push(fillableAmountIn);
        quoteOuts.push(amountOut);
    }
}
