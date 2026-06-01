// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFermiSwapper} from "../../src/interfaces/IFermiSwapper.sol";
import {IBebopRouter} from "../../src/interfaces/IBebopRouter.sol";
import {IKipseliPAMM} from "../../src/interfaces/IKipseliPAMM.sol";
import {IKipseliQuoter} from "../../src/interfaces/IKipseliQuoter.sol";

/// @notice Mock of FermiSwap: pulls `tokenIn` via allowance and delivers a
/// configurable `output` of `tokenOut` to `recipient`. Pre-fund with `tokenOut`.
contract MockFermi is IFermiSwapper {
    uint256 public output;

    function setOutput(uint256 o) external {
        output = o;
    }

    function fermiSwapWithAllowances(
        address tokenIn,
        address tokenOut,
        int256 amountSpecified,
        uint256 amountCheck,
        address recipient
    ) external returns (uint256, uint256) {
        uint256 amountIn = uint256(amountSpecified);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        require(output >= amountCheck, "MockFermi: insufficient");
        IERC20(tokenOut).transfer(recipient, output);
        return (amountIn, output);
    }

    function quoteAmounts(address, address, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        return (uint256(amountSpecified), output);
    }
}

/// @notice Mock of the Kipseli propAMM: expects `tokenIn` to have been
/// transferred in (push), delivers `output` of `tokenOut` to `recipient`, and
/// returns it. Returns 0 (Kipseli's failure signal) when `returnZero` is set.
contract MockKipseliPamm is IKipseliPAMM {
    uint256 public output;
    bool public returnZero;

    function setOutput(uint256 o) external {
        output = o;
    }

    function setReturnZero(bool r) external {
        returnZero = r;
    }

    function swap(address, uint256, address tokenOut, address recipient) external returns (uint256) {
        if (returnZero) {
            return 0;
        }
        IERC20(tokenOut).transfer(recipient, output);
        return output;
    }
}

/// @notice Mock of the Kipseli quoter. Unlike the real quoter, it does not
/// require the caller to hold `tokenIn`.
contract MockKipseliQuoter is IKipseliQuoter {
    uint256 public quoteOut;

    function setQuote(uint256 q) external {
        quoteOut = q;
    }

    function preSwapQuote(address, uint256, address, uint256, address) external view returns (uint256) {
        return quoteOut;
    }
}

/// @notice Mock of the Bebop router: pulls `tokenIn` via allowance, enforces
/// `deadline` and `amountOutMin`, and delivers `output` of `tokenOut` to
/// `msg.sender` (Bebop has no recipient arg). Pre-fund with `tokenOut`.
contract MockBebop is IBebopRouter {
    uint256 public output;

    function setOutput(uint256 o) external {
        output = o;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, uint256 deadline)
        external
    {
        require(block.timestamp <= deadline, "MockBebop: expired");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        require(output >= amountOutMin, "MockBebop: insufficient");
        IERC20(tokenOut).transfer(msg.sender, output);
    }

    function quote(address, address, uint256) external view returns (uint256) {
        return output;
    }
}
