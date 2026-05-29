// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PropAMMRouter} from "./PropAMMRouter.sol";
import {UniV3Router} from "./libraries/UniV3Router.sol";

/// @title PropAMMRouterWithFee
/// @notice PropAMMRouter variant that skims a bps fee from each swap's output
/// before delivery — fee logic baked into the router instead of layered via a
/// separate wrapper. Drop-in replacement for PropAMMRouter from a caller's
/// point of view (same `swap` signature; the user receives `amountIn` of
/// `tokenIn` swapped, minus `feeBps` of the gross output skimmed to
/// `feeRecipient`).
/// @dev Eliminates the extra tokenIn `transferFrom` hop and tokenIn `approve`
/// the wrapper pattern incurs. The swap path becomes
/// `user → router → (feeRecipient, user)` instead of
/// `user → wrapper → router → wrapper → (feeRecipient, user)`.
contract PropAMMRouterWithFee is PropAMMRouter {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 100; // 1.00%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    // Packed into a single slot with `feeBps` (uint16 fits in the same 32-byte
    // word as the address) so a swap reads both fields in one cold SLOAD.
    address public feeRecipient;
    uint16 public feeBps;

    error FeeBpsTooHigh(uint16 requested, uint16 max);
    error InvalidFeeRecipient();

    event FeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeCollected(address indexed tokenOut, uint256 amount, address indexed feeRecipient, address indexed user);

    /// @notice Initializes the fee-skimming router. Calling the inherited
    /// 3-arg `PropAMMRouter.initialize` directly is intentionally disabled
    /// (overridden below) so a deployment can't forget the fee config.
    function initialize(
        address fallbackSwapRouter_,
        address fallbackQuoter_,
        address owner_,
        address feeRecipient_,
        uint16 feeBps_
    ) public initializer {
        if (feeRecipient_ == address(0) || feeRecipient_ == address(this)) revert InvalidFeeRecipient();
        if (feeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh(feeBps_, MAX_FEE_BPS);

        // Mirror PropAMMRouter.initialize body — we can't call it directly
        // because both functions would race the `initializer` modifier.
        fallbackSwapRouter = fallbackSwapRouter_;
        fallbackQuoter = fallbackQuoter_;
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();

        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    /// @dev Disables the inherited no-fee initializer. A caller front-running
    /// deployment with the 3-arg signature would otherwise lock the proxy
    /// without any fee config. Reverts after the modifier set version=1, so
    /// the entire tx rolls back — the proxy stays uninitialized.
    function initialize(address, address, address) public pure override {
        revert("Use initialize(address,address,address,address,uint16)");
    }

    function setFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeBpsTooHigh(newBps, MAX_FEE_BPS);
        emit FeeBpsUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) || newRecipient == address(this)) revert InvalidFeeRecipient();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @inheritdoc PropAMMRouter
    /// @dev Re-implements the parent's `swap` (rather than wrapping it via
    /// `super.swap`) because the parent's `nonReentrant` guard would block a
    /// nested call. The venue/fallback dispatch is preserved verbatim — only
    /// the recipient is redirected to `address(this)` so the router holds
    /// gross output, then splits into `fee` and `userAmount` and delivers
    /// each with one `safeTransfer`. `grossMin` scales `amountOutMin` up by
    /// the fee so the slippage guarantee remains in caller-visible terms.
    function swap(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 uniswapFee,
        uint256 deadline
    ) public override whenNotPaused nonReentrant returns (uint256) {
        require(block.timestamp <= deadline, Expired());
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint16 _feeBps = feeBps; // single cold SLOAD; reused below
        uint256 grossMin = Math.ceilDiv(amountOutMin * BPS_DENOMINATOR, BPS_DENOMINATOR - _feeBps);

        uint256 prevBalance = IERC20(tokenOut).balanceOf(address(this));

        uint256 gross;
        try
            this.swapViaVenue(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline, prevBalance)
        returns (uint256 g) {
            gross = g;
        } catch {
            UniV3Router.swapExactIn(
                tokenIn, tokenOut, uniswapFee, amountIn, grossMin, address(this), fallbackSwapRouter
            );
            gross = IERC20(tokenOut).balanceOf(address(this)) - prevBalance;
            require(gross >= grossMin, InsufficientOutput(grossMin, gross));
        }

        uint256 fee = gross * _feeBps / BPS_DENOMINATOR;
        uint256 userAmount = gross - fee;

        if (fee > 0) {
            IERC20(tokenOut).safeTransfer(feeRecipient, fee);
            emit FeeCollected(tokenOut, fee, feeRecipient, msg.sender);
        }
        if (userAmount > 0) {
            IERC20(tokenOut).safeTransfer(recipient, userAmount);
        }
        return userAmount;
    }
}
