// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPropAMM} from "../interfaces/IPropAMM.sol";
import {IKipseliPAMM} from "../interfaces/IKipseliPAMM.sol";
import {IKipseliQuoter} from "../interfaces/IKipseliQuoter.sol";

/// @title KipseliAdapter
/// @notice Wraps the Kipseli propAMM behind `IPropAMM` so `PropAMMRouter` can
/// route to it through the uniform whitelist.
/// @dev Holds no funds between swaps. Kipseli uses push-payment (it expects the
/// input transferred in) and signals failure by returning 0; its pricing lives
/// in a separate quoter contract.
contract KipseliAdapter is IPropAMM {
    using SafeERC20 for IERC20;

    /// @notice The Kipseli propAMM this adapter wraps.
    address public immutable kipseliPamm;
    /// @notice The Kipseli quoter used to price swaps.
    address public immutable kipseliQuoter;

    /// @notice Thrown when constructed with a zero address.
    error ZeroAddress();
    /// @notice Thrown when Kipseli returns 0 (its failure signal) or delivers
    /// below `minAmountOut`, so the router's fallback engages.
    error KipseliSwapFailed();

    constructor(address kipseliPamm_, address kipseliQuoter_) {
        require(kipseliPamm_ != address(0) && kipseliQuoter_ != address(0), ZeroAddress());
        kipseliPamm = kipseliPamm_;
        kipseliQuoter = kipseliQuoter_;
    }

    /// @inheritdoc IPropAMM
    /// @dev Conservatively reports active; real liveness is enforced by `quote`
    /// and `swap` reverting. Kipseli exposes no per-pair liveness view.
    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IPropAMM
    /// @dev Kipseli does not enumerate pairs; returns empty.
    function getPairs() external pure returns (Pair[] memory pairs) {
        return pairs;
    }

    /// @inheritdoc IPropAMM
    /// @dev Prices via Kipseli's separate quoter. The live Kipseli quoter pulls
    /// `tokenIn` from the caller, so an on-chain `quote` with no balance reverts
    /// — Kipseli then simply isn't auto-selected by `swapV1`'s best-quote scan
    /// (it is skipped by the router's try/catch); it stays reachable via
    /// `swapViaVenueV1`.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        amountOut =
            IKipseliQuoter(kipseliQuoter).preSwapQuote(tokenIn, amountIn, tokenOut, block.timestamp * 1000, address(0));
    }

    /// @inheritdoc IPropAMM
    /// @dev Push-payment: transfers the pushed `amountIn` to Kipseli, then
    /// swaps. Reverts `KipseliSwapFailed` on Kipseli's 0-return failure signal
    /// or an under-fill below `minAmountOut` (Kipseli takes no minimum
    /// parameter), so the router's fallback engages.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
    {
        IERC20(tokenIn).safeTransfer(kipseliPamm, amountIn);
        uint256 amountOut = IKipseliPAMM(kipseliPamm).swap(tokenIn, amountIn, tokenOut, recipient);
        require(amountOut != 0 && amountOut >= minAmountOut, KipseliSwapFailed());
    }
}
