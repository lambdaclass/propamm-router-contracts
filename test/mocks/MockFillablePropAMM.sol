// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";
import {IPropAMMFillable} from "../../src/interfaces/IPropAMMFillable.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A propAMM that advertises `IPropAMMFillable`. Every reported value
/// is settable so a test can drive an honest venue, an over-reporting venue,
/// or one that lies about supporting the interface.
contract MockFillablePropAMM is IPropAMM, IPropAMMFillable, IERC165 {
    uint256 public fillableToReturn;
    uint256 public outToReturn;
    uint256 public amountOutToDeliver;
    bool public supportsFillable = true;
    /// @notice `quoteFillable` reverts instead of returning when true. Models a
    /// venue that reverts when it has no inventory left. Defaults to false so
    /// every pre-existing test keeps its original (non-reverting) behavior.
    bool public revertOnQuoteFillable;
    /// @notice Rate (in bps of `amountIn`) the blind two-point probe's `quote`
    /// sees, independent of `fillableToReturn`/`outToReturn`. Defaults to 0,
    /// matching this mock's original hardcoded-zero `quote`, so no pre-existing
    /// test changes. Set this to a live, attractive rate in a test that must
    /// prove a decline comes from the extension branch itself rather than from
    /// the venue being unreachable through the blind probe too.
    uint256 public quoteRateBps;

    function setFillable(uint256 v) external {
        fillableToReturn = v;
    }

    function setOut(uint256 v) external {
        outToReturn = v;
    }

    function setAmountOut(uint256 v) external {
        amountOutToDeliver = v;
    }

    function setSupportsFillable(bool v) external {
        supportsFillable = v;
    }

    function setRevertOnQuoteFillable(bool v) external {
        revertOnQuoteFillable = v;
    }

    function setQuoteRateBps(uint256 v) external {
        quoteRateBps = v;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (interfaceId == type(IPropAMMFillable).interfaceId) return supportsFillable;
        return interfaceId == type(IERC165).interfaceId;
    }

    function quoteFillable(address, address, uint256) external view returns (uint256, uint256) {
        if (revertOnQuoteFillable) revert("MockFillablePropAMM: quoteFillable reverted");
        return (fillableToReturn, outToReturn);
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory) {
        return new TokenPair[](0);
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        return amountIn * quoteRateBps / 10_000;
    }

    function swap(address, address tokenOut, uint256, uint256, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        amountOut = amountOutToDeliver;
        MockERC20(tokenOut).mint(recipient, amountOut);
        return amountOut;
    }
}
