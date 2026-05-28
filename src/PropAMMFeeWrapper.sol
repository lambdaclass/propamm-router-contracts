// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "./interfaces/IPropAMMRouter.sol";

/// @title PropAMMFeeWrapper
/// @notice UUPS-upgradeable drop-in front of PropAMMRouter that takes a bps fee
/// out of the swap output token. Mirrors IPropAMMRouter so off-chain callers only
/// repoint one address.
contract PropAMMFeeWrapper is
    IPropAMMRouter,
    Initializable,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 100; // 1.00%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    address public router;
    address public feeRecipient;
    uint16 public feeBps;

    error FeeBpsTooHigh(uint16 requested, uint16 max);
    error ZeroAddress();
    error IdenticalTokens();

    event FeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeCollected(address indexed tokenOut, uint256 amount, address indexed recipient, address indexed user);
    event SwapExecuted(
        address indexed user,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address router_, address feeRecipient_, uint16 feeBps_, address owner_)
        public
        initializer
    {
        if (router_ == address(0) || feeRecipient_ == address(0) || feeRecipient_ == address(this)) {
            revert ZeroAddress();
        }
        if (feeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh(feeBps_, MAX_FEE_BPS);
        router = router_;
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    function setFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeBpsTooHigh(newBps, MAX_FEE_BPS);
        emit FeeBpsUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) || newRecipient == address(this)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IPropAMMRouter
    function swap(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 uniswapFee,
        uint256 deadline
    ) external whenNotPaused nonReentrant returns (uint256) {
        require(tokenIn != tokenOut, IdenticalTokens());

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(router, amountIn);

        uint256 grossMin = Math.ceilDiv(uint256(amountOutMin) * BPS_DENOMINATOR, BPS_DENOMINATOR - feeBps);

        uint256 delivered = IPropAMMRouter(router).swap(
            venue, tokenIn, tokenOut, amountIn, grossMin, address(this), uniswapFee, deadline
        );

        uint256 fee = _feeOf(delivered);
        uint256 userAmount = delivered - fee;

        if (fee > 0) {
            IERC20(tokenOut).safeTransfer(feeRecipient, fee);
            emit FeeCollected(tokenOut, fee, feeRecipient, msg.sender);
        }
        if (userAmount > 0) {
            IERC20(tokenOut).safeTransfer(recipient, userAmount);
        }
        emit SwapExecuted(msg.sender, recipient, tokenIn, tokenOut, amountIn, userAmount, fee);
        return userAmount;
    }

    /// @inheritdoc IPropAMMRouter
    function quote(address tokenIn, address tokenOut, uint256 amount, uint24 uniswapFee)
        external
        returns (uint256 bestQuote, Venue venue)
    {
        uint256 gross;
        (gross, venue) = IPropAMMRouter(router).quote(tokenIn, tokenOut, amount, uniswapFee);
        bestQuote = gross - _feeOf(gross);
    }

    /// @inheritdoc IPropAMMRouter
    function quote(address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 bestQuote, Venue venue)
    {
        uint256 gross;
        (gross, venue) = IPropAMMRouter(router).quote(tokenIn, tokenOut, amount);
        bestQuote = gross - _feeOf(gross);
    }

    /// @inheritdoc IPropAMMRouter
    function quoteVenue(Venue venue, address tokenIn, address tokenOut, uint256 amount, uint24 uniswapFee)
        external
        returns (uint256 amountOut)
    {
        uint256 gross = IPropAMMRouter(router).quoteVenue(venue, tokenIn, tokenOut, amount, uniswapFee);
        amountOut = gross - _feeOf(gross);
    }

    /// @inheritdoc IPropAMMRouter
    function quoteVenue(Venue venue, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 amountOut)
    {
        uint256 gross = IPropAMMRouter(router).quoteVenue(venue, tokenIn, tokenOut, amount);
        amountOut = gross - _feeOf(gross);
    }

    function _feeOf(uint256 amount) private view returns (uint256) {
        return amount * feeBps / BPS_DENOMINATOR;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
