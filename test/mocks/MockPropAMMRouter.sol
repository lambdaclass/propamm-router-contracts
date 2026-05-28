// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../../src/interfaces/IPropAMMRouter.sol";

/// @notice Configurable IPropAMMRouter stub. `swap` pulls tokenIn from the caller
/// (the wrapper) and sends `amountOutToReturn` of tokenOut to `recipient`,
/// mimicking the real router's "deliver to recipient, return the measured delta" contract.
contract MockPropAMMRouter is IPropAMMRouter {
    uint256 public amountOutToReturn;
    uint256 public quoteToReturn;
    Venue public quoteVenueToReturn;
    bool public shouldRevert;

    uint256 public lastAmountOutMin;
    address public lastRecipient;

    error Expired();
    error MockForcedRevert();
    error MockInsufficientOutput();

    function setAmountOut(uint256 v) external { amountOutToReturn = v; }
    function setQuote(uint256 gross, Venue v) external { quoteToReturn = gross; quoteVenueToReturn = v; }
    function setShouldRevert(bool v) external { shouldRevert = v; }

    function swap(
        Venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24,
        uint256 deadline
    ) external returns (uint256) {
        require(block.timestamp <= deadline, Expired());
        if (shouldRevert) revert MockForcedRevert();
        lastAmountOutMin = amountOutMin;
        lastRecipient = recipient;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // Faithful to the real router: deliver to recipient, then RETURN the
        // measured balance delta (not the nominal amount). This is what makes
        // fee-on-transfer tokenOut work — the wrapper trusts this return value.
        uint256 prevBal = IERC20(tokenOut).balanceOf(recipient);
        IERC20(tokenOut).transfer(recipient, amountOutToReturn);
        uint256 delta = IERC20(tokenOut).balanceOf(recipient) - prevBal;
        if (delta < amountOutMin) revert MockInsufficientOutput();
        return delta;
    }

    function quote(address, address, uint256, uint24) external view returns (uint256, Venue) {
        return (quoteToReturn, quoteVenueToReturn);
    }

    function quote(address, address, uint256) external view returns (uint256, Venue) {
        return (quoteToReturn, quoteVenueToReturn);
    }

    function quoteVenue(Venue, address, address, uint256, uint24) external view returns (uint256) {
        return quoteToReturn;
    }

    function quoteVenue(Venue, address, address, uint256) external view returns (uint256) {
        return quoteToReturn;
    }
}
