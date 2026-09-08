// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";

/// @notice The mirror image of {MockThievingQuoteVenue}: this venue SENDS the
/// caller 1 wei of tokenIn during `quote()` instead of taking one. It has
/// removed nothing from the router, so the R1 invariant — which exists to
/// catch the router LOSING pulled funds while it quotes — must not treat it
/// as theft. Under an equality bracket it would, and one such venue anywhere
/// in the whitelist would revert every `swapSplitV1` call, including calls
/// that never intended to route through it.
///
/// The quote is deliberately unattractive so the donation, not the ranking,
/// is what the test is pinning.
contract MockDonatingQuoteVenue is IPropAMM {
    using SafeERC20 for IERC20;

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (IPropAMM.TokenPair[] memory pairs) {
        return pairs;
    }

    function quote(address tokenIn, address, uint256 amountIn) external returns (uint256) {
        IERC20(tokenIn).safeTransfer(msg.sender, 1);
        return amountIn / 2;
    }

    function swap(address, address, uint256, uint256, address, uint256) external pure returns (uint256) {
        revert("never fills");
    }
}
