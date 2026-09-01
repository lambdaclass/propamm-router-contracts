// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPropAMM} from "../../src/interfaces/IPropAMM.sol";

/// @notice Configurable flat-price venue with a capacity and one of the three
/// above-cap behaviors measured in Phase 0: hard revert, saturating quote
/// (fixed max output for any larger input), or zero quote. Push-payment like
/// the real venues. `honorMinOut=false` + `shortChangeBps` model a venue that
/// under-delivers its own quote (must trip the router's per-leg min).
contract MockCappedPropAMM is IPropAMM {
    using SafeERC20 for IERC20;

    enum CapMode {
        HardRevert,
        Saturate,
        ZeroQuote
    }

    uint256 public priceNum;
    uint256 public priceDen; // out = in * priceDen / priceNum
    uint256 public cap; // max fillable amountIn; 0 = uncapped
    CapMode public capMode = CapMode.HardRevert;
    bool public active = true;
    bool public honorMinOut = true;
    uint256 public shortChangeBps; // swap delivers out * (10000 - bps) / 10000

    IPropAMM.TokenPair[] private _pairs;

    constructor(uint256 priceNum_, uint256 priceDen_) {
        priceNum = priceNum_;
        priceDen = priceDen_;
    }

    function setCap(uint256 cap_) external {
        cap = cap_;
    }

    function setCapMode(CapMode mode) external {
        capMode = mode;
    }

    function setActive(bool active_) external {
        active = active_;
    }

    function setHonorMinOut(bool honor) external {
        honorMinOut = honor;
    }

    function setShortChangeBps(uint256 bps) external {
        shortChangeBps = bps;
    }

    function setPrice(uint256 num, uint256 den) external {
        priceNum = num;
        priceDen = den;
    }

    function isActive(address, address) external view returns (bool) {
        return active;
    }

    function getPairs() external view returns (IPropAMM.TokenPair[] memory) {
        return _pairs;
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        require(active, "inactive");
        if (cap != 0 && amountIn > cap) {
            if (capMode == CapMode.HardRevert) revert("cap");
            if (capMode == CapMode.ZeroQuote) return 0;
            return cap * priceDen / priceNum; // Saturate
        }
        return amountIn * priceDen / priceNum;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        require(active, "inactive");
        require(cap == 0 || amountIn <= cap, "cap");
        amountOut = amountIn * priceDen / priceNum;
        amountOut = amountOut * (10_000 - shortChangeBps) / 10_000;
        if (honorMinOut) require(amountOut >= minAmountOut, "slippage");
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }
}
