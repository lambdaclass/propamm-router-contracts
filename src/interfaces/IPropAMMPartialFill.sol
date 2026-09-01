// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "./IPropAMM.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPropAMMPartialFill
/// @notice Optional extension of {IPropAMM} for venues that can report the
/// largest portion of an order they can fill right now. One call returns
/// both inputs the router's split planner needs (price and capacity),
/// replacing the two-point probe of the degraded mode.
/// @dev Because partial-fill reporting is optional, this interface also
/// inherits {IERC165} so the router and off-chain integrators can detect
/// support at runtime without a trial call — e.g. `ERC165Checker.supportsInterface(venue,
/// type(IPropAMMPartialFill).interfaceId)`. A conforming venue MUST report `true`
/// from `supportsInterface` for `type(IERC165).interfaceId`,
/// `type(IPropAMM).interfaceId`, and `type(IPropAMMPartialFill).interfaceId`.
/// Note `type(IPropAMMPartialFill).interfaceId` covers only the
/// `quotePartialFill` selector declared here (Solidity excludes inherited
/// functions), so it is distinct from `type(IPropAMM).interfaceId` — a venue
/// that advertises only one of the three is not fully detectable. Plain
/// exact-input venues that do not implement ERC165 are still supported: an
/// `ERC165Checker` probe returns `false` for them rather than reverting.
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
