// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPropAMM} from "./IPropAMM.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IPropAMMExactOut
/// @notice Optional extension of {IPropAMM} for proprietary AMMs that also
/// support exact-output swaps: the caller fixes the exact `amountOut` of
/// `tokenOut` it wants and a ceiling `amountInMax` on what it will spend.
/// @dev Inherits the full exact-input surface (`isActive`, `getPairs`, `quote`,
/// `swap`), the `TokenPair` struct, and the `Swapped` event from {IPropAMM}, so
/// a venue implementing this interface supports BOTH exact-input and
/// exact-output. The router uses the same push-payment model as exact-input,
/// but because the input amount is not known up front it transfers
/// `amountInMax` and the venue MUST refund the unspent remainder (see
/// `swapExactOut`).
///
/// Because exact-output is optional, this interface also inherits {IERC165} so
/// the router and off-chain integrators can detect support at runtime without a
/// trial swap — e.g. `ERC165Checker.supportsInterface(venue,
/// type(IPropAMMExactOut).interfaceId)`. A conforming venue MUST report `true`
/// from `supportsInterface` for `type(IERC165).interfaceId`,
/// `type(IPropAMM).interfaceId`, and `type(IPropAMMExactOut).interfaceId`.
/// Note `type(IPropAMMExactOut).interfaceId` covers only the exact-output
/// selectors declared here (Solidity excludes inherited functions), so it is
/// distinct from `type(IPropAMM).interfaceId`. Plain exact-input venues that do
/// not implement ERC165 are still supported: an `ERC165Checker` probe returns
/// `false` for them rather than reverting.
interface IPropAMMExactOut is IPropAMM, IERC165 {
    /// @notice Quotes the `tokenIn` amount required to receive an exact
    /// `amountOut` of `tokenOut`.
    /// @dev The exact-output mirror of {IPropAMM-quote}: it inverts the
    /// known/unknown sides, fixing `amountOut` and returning the required
    /// `amountIn`. MUST revert if the propAMM is inactive for the pair.
    /// MUST NOT require a `tokenIn` balance or allowance from the caller.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountOut The exact amount of `tokenOut` to receive.
    /// @return amountIn The amount of `tokenIn` the swap would require.
    function quoteExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut
    ) external returns (uint256 amountIn);

    /// @notice Swaps as little `tokenIn` as needed to deliver an exact
    /// `amountOut` of `tokenOut` to `recipient`, spending at most `amountInMax`.
    /// @dev Push-payment: the caller transfers `amountInMax` of `tokenIn` to the
    /// propAMM BEFORE this call. The propAMM:
    ///  - MUST deliver exactly `amountOut` of `tokenOut` to `recipient`;
    ///  - MUST consume at most `amountInMax` of `tokenIn`, and SHALL revert if
    ///    delivering `amountOut` would require more;
    ///  - MUST refund any unspent `tokenIn` (`amountInMax - amountIn`) to
    ///    `refundRecipient`.
    /// SHALL revert if the pair is inactive. The `deadline` can safely be
    /// ignored when coming from the Router, since it already does the check.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountOut The exact amount of `tokenOut` to deliver to `recipient`.
    /// @param amountInMax The maximum amount of `tokenIn` the caller will spend;
    /// also the amount the caller pushes to the propAMM up front.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param refundRecipient The address to refund the unspent `tokenIn` to.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountIn The amount of `tokenIn` actually consumed by the swap.
    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        address refundRecipient,
        uint256 deadline
    ) external returns (uint256 amountIn);
}
