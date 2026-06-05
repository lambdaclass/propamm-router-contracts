// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPropAMMRouter} from "../interfaces/IPropAMMRouter.sol";
import {ETH_SENTINEL, WETH} from "./Constants.sol";
import {ETHTransferFailed, ZeroAddress} from "./Errors.sol";

/// @title FrontendFees
/// @notice Util functions for managing optional frontend fees
library FrontendFees {
    using SafeERC20 for IERC20;

    /// @notice Hard cap on a frontend fee, in basis points (1.00%).
    uint16 public constant MAX_FEE_BPS = 100;
    /// @notice Basis-point denominator (100% = 10_000 bps).
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Thrown when a requested frontend fee exceeds `MAX_FEE_BPS`.
    /// @param requested The caller-supplied fee in basis points.
    /// @param max The maximum allowed fee (`MAX_FEE_BPS`).
    error FeeBpsTooHigh(uint16 requested, uint16 max);

    /// @notice Reverts unless the frontend fee is within cap and has a real recipient.
    /// @param fee The caller-supplied fee parameters.
    function _validateFee(IPropAMMRouter.FrontendFee calldata fee) internal pure {
        require(fee.bps <= MAX_FEE_BPS, FeeBpsTooHigh(fee.bps, MAX_FEE_BPS));
        require(fee.recipient != address(0), ZeroAddress());
    }

    /// @notice Grosses up a net `amountOutMin` so the post-fee output still meets it.
    /// @dev `ceilDiv` rounds up to avoid a 1-wei false revert at the slippage boundary.
    /// Safe from divide-by-zero because `feeBps <= MAX_FEE_BPS < BPS_DENOMINATOR`.
    /// @param amountOutMin The net minimum the user must receive.
    /// @param feeBps The fee in basis points.
    /// @return grossMin The gross minimum the underlying swap must deliver.
    function _grossUp(uint256 amountOutMin, uint16 feeBps) internal pure returns (uint256 grossMin) {
        grossMin = Math.ceilDiv(amountOutMin * BPS_DENOMINATOR, BPS_DENOMINATOR - feeBps);
    }

    /// @notice Floored basis-point fee on `amount`.
    /// @param amount The gross amount the fee is taken from.
    /// @param feeBps The fee in basis points.
    /// @return The fee amount (rounds down, favoring the user).
    function _feeAmount(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return amount * feeBps / BPS_DENOMINATOR;
    }

    /// @notice Splits `delivered` tokenOut (held by this contract) into fee + net,
    /// forwards the fee to `fee.recipient` and the net to `recipient`.
    /// @dev Zero-value legs are skipped (gas + tokens that revert on 0-value transfers).
    /// @param tokenOut The output token held by this contract.
    /// @param delivered The gross amount this contract received from the swap.
    /// @param fee The fee parameters.
    /// @param recipient The end recipient of the net output.
    /// @return net The amount forwarded to `recipient`.
    function _skimAndDisburse(
        address tokenOut,
        uint256 delivered,
        IPropAMMRouter.FrontendFee calldata fee,
        address recipient
    ) internal returns (uint256 net) {
        uint256 feeAmt = _feeAmount(delivered, fee.bps);
        net = delivered - feeAmt;
        if (feeAmt > 0) {
            if (tokenOut == ETH_SENTINEL) {
                (bool ok,) = fee.recipient.call{value: feeAmt}("");
                require(ok, ETHTransferFailed());
            } else {
                IERC20(tokenOut).safeTransfer(fee.recipient, feeAmt);
            }
            emit IPropAMMRouter.FrontendFeeCharged(fee.recipient, tokenOut, feeAmt, msg.sender);
        }
        if (net > 0) {
            if (tokenOut == ETH_SENTINEL) {
                (bool ok,) = recipient.call{value: net}("");
                require(ok, ETHTransferFailed());
            } else {
                IERC20(tokenOut).safeTransfer(recipient, net);
            }
        }
    }
}
