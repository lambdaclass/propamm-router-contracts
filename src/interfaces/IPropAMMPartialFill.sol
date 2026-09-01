// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "./IPropAMM.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPropAMMPartialFill
/// @notice Optional extension of {IPropAMM} for venues that can report the
/// largest portion of an order they can fill right now. One call returns
/// both inputs the router's split planner needs (price and capacity),
/// replacing the two-point probe of the degraded mode.
/// @dev Like {IPropAMMExactOut}, detection is via ERC165:
/// `supportsInterface(type(IPropAMMPartialFill).interfaceId)`.
/// Requirements:
///  - `fillableAmountIn` MUST be ≤ `amountIn`;
///  - `amountOut` MUST be what a swap of exactly `fillableAmountIn` would
///    deliver in this block;
///  - MUST return `(0, 0)` rather than revert when the pair is active but
///    currently unfillable;
///  - MUST NOT require a `tokenIn` balance or allowance from the caller —
///    the router verifies a balance invariant across its quote phase and
///    treats net consumption as an attack.
interface IPropAMMPartialFill is IPropAMM, IERC165 {
    /// @notice Quotes the largest portion of `amountIn` this venue can fill
    /// right now, and the `tokenOut` amount that portion would deliver.
    /// @dev See the requirements in the contract-level `@dev` note above.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The amount of `tokenIn` the caller would like to sell.
    /// @return fillableAmountIn The portion of `amountIn` this venue can fill now.
    /// @return amountOut The amount of `tokenOut` a swap of `fillableAmountIn` would deliver.
    function quotePartialFill(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 fillableAmountIn, uint256 amountOut);
}
