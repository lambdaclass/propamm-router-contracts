// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {IPropAMMExactOut} from "../../src/interfaces/IPropAMMExactOut.sol";

/// @notice A minimal venue implementing the full {IPropAMMExactOut} surface
/// (inherited exact-input + exact-output) against a fixed linear price, used to
/// prove the interface is implementable as specified. Price is expressed as a
/// ratio: delivering `amountOut` costs `ceil(amountOut * priceNum / priceDen)`
/// of `tokenIn`; selling `amountIn` yields `amountIn * priceDen / priceNum`.
/// The venue is funded with `tokenOut` liquidity ahead of time and follows the
/// push-payment model: the caller transfers the input to this contract before
/// calling `swap` / `swapExactOut`.
contract MockPropAMMExactOut is IPropAMMExactOut {
    using SafeERC20 for IERC20;

    uint256 public priceNum;
    uint256 public priceDen;
    bool public active = true;

    IPropAMM.TokenPair[] private _pairs;

    constructor(uint256 priceNum_, uint256 priceDen_) {
        priceNum = priceNum_;
        priceDen = priceDen_;
    }

    function setActive(bool active_) external {
        active = active_;
    }

    function addPair(address token0, address token1) external {
        _pairs.push(IPropAMM.TokenPair(token0, token1));
    }

    function isActive(address, address) external view returns (bool) {
        return active;
    }

    function getPairs() external view returns (IPropAMM.TokenPair[] memory) {
        return _pairs;
    }

    /// @notice ERC165 detection: advertises ERC165 itself, the exact-input base
    /// {IPropAMM}, and the exact-output extension {IPropAMMExactOut}.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IPropAMM).interfaceId
            || interfaceId == type(IPropAMMExactOut).interfaceId;
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256 amountOut) {
        require(active, "inactive");
        amountOut = amountIn * priceDen / priceNum;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        require(active, "inactive");
        amountOut = amountIn * priceDen / priceNum;
        require(amountOut >= minAmountOut, "slippage");
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    // --- exact-output ------------------------------------------------------

    function quoteExactOut(address, address, uint256 amountOut) external view returns (uint256 amountIn) {
        require(active, "inactive");
        // Round up so the venue is never under-charged for the exact output.
        amountIn = Math.ceilDiv(amountOut * priceNum, priceDen);
    }

    function swapExactOut(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        address refundRecipient,
        uint256
    ) external returns (uint256 amountIn) {
        require(active, "inactive");
        amountIn = Math.ceilDiv(amountOut * priceNum, priceDen);
        require(amountIn <= amountInMax, "exceeds amountInMax");

        // Deliver exactly amountOut from the venue's liquidity.
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        // Refund the unspent input pushed up front to the refund recipient.
        uint256 refund = amountInMax - amountIn;
        if (refund > 0) {
            IERC20(tokenIn).safeTransfer(refundRecipient, refund);
        }
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }
}
