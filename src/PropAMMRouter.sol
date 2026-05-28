// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "./interfaces/IPropAMMRouter.sol";
import {FERMI_ROUTER, IFermiSwapper} from "./interfaces/IFermiSwapper.sol";
import {BEBOP_ROUTER, IBebopRouter} from "./interfaces/IBebopRouter.sol";
import {KIPSELI_PAMM, IKipseliPAMM} from "./interfaces/IKipseliPAMM.sol";
import {KIPSELI_QUOTER, IKipseliQuoter} from "./interfaces/IKipseliQuoter.sol";
import {UniV3Router} from "./libraries/UniV3Router.sol";

/// @title PropAMMRouter
/// @notice Routes single-hop swaps to a proprietary AMM (FermiSwap, Kipseli, or
/// Bebop) or directly to Uniswap V3, and falls back to Uniswap V3 if the
/// chosen proprietary venue reverts.
/// @dev Designed to live behind a UUPS proxy. The fallback path is wired at
/// initialization via `fallbackSwapRouter` (SwapRouter02) and `fallbackQuoter`
/// (QuoterV2); proprietary venue addresses are hardcoded as constants. The
/// owner authorized in `initialize` controls upgrades via `_authorizeUpgrade`.
contract PropAMMRouter is
    IPropAMMRouter,
    ReentrancyGuardTransient,
    Initializable,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Uniswap V3 SwapRouter02 used when the proprietary AMM swap reverts.
    address fallbackSwapRouter;
    /// @notice Uniswap V3 QuoterV2 used to price the fallback route off-chain.
    address fallbackQuoter;

    /// @notice Default Uniswap V3 pool fee tier (in hundredths of a bip) used
    /// by the no-fee `quote` and `quoteVenue` overloads when pricing the
    /// `Venue.Fallback` branch. `3000` = 0.30%, a common "blue-chip" tier
    /// but not always the deepest pool for a given pair — callers wanting a
    /// different pool should use the explicit-fee overloads.
    uint24 public constant DEFAULT_FALLBACK_FEE = 3000;

    /// @notice Thrown when `swapViaVenue` is called by anyone other than this
    /// contract itself, i.e. outside of the `try`-wrapped self-call made by `swap`.
    error OnlySelf();
    /// @notice Thrown when `venue` does not match any supported `Venue` value.
    error UnknownVenue();
    /// @notice Thrown when `swap` cannot deliver at least `amountOutMin` of
    /// `tokenOut` to `recipient`.
    /// @param expectedAmount The minimum acceptable amount of `tokenOut` (i.e.
    /// the caller's `amountOutMin`).
    /// @param receivedAmount The actual amount of `tokenOut` delivered to
    /// `recipient`, measured as a balance delta against the pre-swap snapshot.
    error InsufficientOutput(uint256 expectedAmount, uint256 receivedAmount);
    /// @notice Thrown when `swap` is invoked after its `deadline`.
    error Expired();
    /// @notice Thrown when no proprietary venue can produce a quote for the
    /// requested pair and amount.
    error NoQuotesAvailable();
    /// @notice Thrown when `tokenOut` balance decreases after a swap.
    error TokenOutBalanceDecreased();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the router, pinning the Uniswap V3 fallback contracts
    /// and setting the owner who controls future upgrades.
    /// @param fallbackSwapRouter_ Address of the Uniswap V3 SwapRouter02 used
    /// to execute the fallback swap.
    /// @param fallbackQuoter_ Address of the Uniswap V3 QuoterV2 used to quote
    /// the fallback swap off-chain.
    /// @param owner_ Initial owner of the proxy. Set directly here with no
    /// acceptance step — `Ownable2Step`'s two-step handoff only governs
    /// *subsequent* transfers via `transferOwnership` / `acceptOwnership`.
    /// Controls `_authorizeUpgrade` and any owner-gated administrative paths.
    /// Reverts if zero (enforced by `__Ownable_init`).
    function initialize(
        address fallbackSwapRouter_,
        address fallbackQuoter_,
        address owner_
    ) public initializer {
        fallbackSwapRouter = fallbackSwapRouter_;
        fallbackQuoter = fallbackQuoter_;
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Picks the winning venue by calling `quote` on-chain, then
    /// executes the swap on it. Funds are pulled from `msg.sender` only
    /// after the quote is known — no quote path requires the router to
    /// hold the input tokens. If the winner is `Venue.Fallback`, the swap
    /// goes directly to `swapViaUniswapV3` (no wasted self-call frame).
    /// Otherwise the winning proprietary venue is invoked through
    /// `this.swapViaVenue` so an execution-time revert can be caught and
    /// recovered with a Uniswap V3 fallback — same recovery flow as
    /// `swapDirect`. The slippage guarantee is enforced in both branches:
    /// `swapViaVenue` reverts on under-fill (triggering the fallback), and
    /// the direct/fallback paths re-measure the balance delta against
    /// `prevTokenOutBalance` and revert `InsufficientOutput` if short.
    /// Reverts `NoQuotesAvailable` (bubbled from `quote`) when no venue
    /// can price the pair.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 uniswapFee,
        uint256 deadline
    )
        public
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut, Venue executedVenue)
    {
        require(block.timestamp <= deadline, Expired());

        (, Venue bestVenue) = quote(tokenIn, tokenOut, amountIn, uniswapFee);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 prevTokenOutBalance = IERC20(tokenOut).balanceOf(recipient);

        if (bestVenue == Venue.Fallback) {
            swapViaUniswapV3(
                tokenIn,
                tokenOut,
                amountIn,
                amountOutMin,
                uniswapFee,
                recipient
            );
            amountOut =
                IERC20(tokenOut).balanceOf(recipient) -
                prevTokenOutBalance;
            require(
                amountOut >= amountOutMin,
                InsufficientOutput(amountOutMin, amountOut)
            );
            executedVenue = Venue.Fallback;
        } else {
            try
                this.swapViaVenue(
                    bestVenue,
                    tokenIn,
                    tokenOut,
                    amountIn,
                    amountOutMin,
                    recipient,
                    deadline,
                    prevTokenOutBalance
                )
            returns (uint256 amountOut_) {
                amountOut = amountOut_;
                executedVenue = bestVenue;
            } catch {
                swapViaUniswapV3(
                    tokenIn,
                    tokenOut,
                    amountIn,
                    amountOutMin,
                    uniswapFee,
                    recipient
                );
                amountOut =
                    IERC20(tokenOut).balanceOf(recipient) -
                    prevTokenOutBalance;
                require(
                    amountOut >= amountOutMin,
                    InsufficientOutput(amountOutMin, amountOut)
                );
                executedVenue = Venue.Fallback;
            }
        }
        return (amountOut, executedVenue);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Pulls `amountIn` of `tokenIn` from `msg.sender` once, then attempts
    /// the chosen venue's swap via an external `this.swapViaVenue` call so a
    /// failure can be caught and recovered with a Uniswap V3 fallback. The
    /// external self-call is intentional: it isolates the venue call's revert
    /// from this function's frame so `try/catch` can engage. The catch arm
    /// doubles as the Uniswap V3 execution path: when `venue` is
    /// `Venue.Fallback`, `swapViaVenue` reverts immediately with no work
    /// done so the catch arm engages and runs Uniswap V3 — a single code
    /// path serves both "proprietary venue failed" and "caller explicitly
    /// asked for Fallback", at the cost of one wasted self-call frame in
    /// the latter case. The slippage guarantee is enforced inside each
    /// branch: `swapViaVenue` checks the measured delta internally before
    /// returning (a failure there reverts and is caught here, triggering
    /// the fallback), and the catch arm re-measures after Uniswap to defend
    /// against an under-delivering fallback router.
    function swapDirect(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint24 uniswapFee,
        uint256 deadline
    ) public whenNotPaused nonReentrant returns (uint256) {
        require(block.timestamp <= deadline, Expired());
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 prevTokenOutBalance = IERC20(tokenOut).balanceOf(recipient);

        uint256 amountOut;
        try
            this.swapViaVenue(
                venue,
                tokenIn,
                tokenOut,
                amountIn,
                amountOutMin,
                recipient,
                deadline,
                prevTokenOutBalance
            )
        returns (uint256 amountOut_) {
            amountOut = amountOut_;
        } catch {
            swapViaUniswapV3(
                tokenIn,
                tokenOut,
                amountIn,
                amountOutMin,
                uniswapFee,
                recipient
            );
            amountOut =
                IERC20(tokenOut).balanceOf(recipient) -
                prevTokenOutBalance;
            require(
                amountOut >= amountOutMin,
                InsufficientOutput(amountOutMin, amountOut)
            );
        }
        return amountOut;
    }

    /// @notice Executes a swap on the selected venue with funds already held
    /// by this contract.
    /// @dev External (not internal) because `swap` invokes it as
    /// `this.swapViaVenue(...)` to wrap the venue call in a try/catch — only
    /// external calls produce a catchable frame, and a revert there also
    /// rolls back the per-venue `forceApprove` issued below. The router must
    /// already hold `amountIn` of `tokenIn`; this function approves the
    /// selected venue for `amountIn` and the venue pulls during its own swap.
    /// Gated on `msg.sender == address(this)` so only the self-call from
    /// `swap` can enter (reverts `OnlySelf` otherwise). For `Venue.Fallback`
    /// this function reverts immediately with no work done so that `swap`'s
    /// existing catch arm runs the Uniswap V3 swap — this deliberately
    /// reuses the catch arm as the single Uniswap V3 execution path (one
    /// place that handles approval reset, balance delta, and slippage
    /// recheck), at the cost of one wasted self-call frame versus branching
    /// in `swap` directly. After the proprietary venue call, measures the
    /// delivered delta on `recipient` and reverts if it is below
    /// `amountOutMin` — by reverting (rather than returning a thin amount)
    /// the under-fill is caught by the outer try/catch in `swap` and
    /// triggers the Uniswap V3 fallback. Also reverts `UnknownVenue` for
    /// unrecognized enum values, or bubbles up the underlying proprietary
    /// router's revert.
    /// @param venue The venue to route the swap through.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`; an
    /// under-fill below this triggers a revert here so the fallback engages.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid;
    /// only honored by venues that enforce it (e.g. Bebop).
    /// @param prevTokenOutBalance `recipient`'s `tokenOut` balance snapshotted
    /// by `swap` before this call, passed through so the delivered delta can
    /// be computed without re-reading the pre-balance.
    /// @return amountOut The amount of `tokenOut` delivered to `recipient`,
    /// measured as the balance delta against `prevTokenOutBalance`.
    function swapViaVenue(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        uint256 prevTokenOutBalance
    ) external returns (uint256) {
        require(msg.sender == address(this), OnlySelf());

        if (venue == Venue.Fallback) {
            // Caller explicitly chose Uniswap V3. Rather than running the
            // fallback inline here, we revert so `swap`'s existing
            // try/catch arm executes the Uniswap V3 path. This funnels both
            // "proprietary venue failed" and "caller asked for Fallback"
            // through one code path — same forceApprove reset, same
            // post-swap balance delta, same `InsufficientOutput` check —
            // at the cost of one wasted self-call frame on the explicit
            // Fallback path. The bare `revert()` carries no data; `swap`'s
            // catch arm is data-agnostic, so the empty payload is fine and
            // saves the gas of encoding a custom error.
            revert();
        } else if (venue == Venue.FermiSwap) {
            IERC20(tokenIn).forceApprove(FERMI_ROUTER, amountIn);
            int256 _amountIn = amountIn.toInt256();
            IFermiSwapper(FERMI_ROUTER).fermiSwapWithAllowances(
                tokenIn,
                tokenOut,
                _amountIn,
                amountOutMin,
                recipient
            );

            // Prevent later transfers if token was partially pulled
            IERC20(tokenIn).forceApprove(FERMI_ROUTER, 0);
        } else if (venue == Venue.Kipseli) {
            IERC20(tokenIn).safeTransfer(KIPSELI_PAMM, amountIn);
            uint256 amountOut_ = IKipseliPAMM(KIPSELI_PAMM).swap(
                tokenIn,
                amountIn,
                tokenOut,
                recipient
            );

            // Kipseli signals failure by returning 0 and keeping `tokenIn`; revert
            // to roll back its transferFrom and let the catch arm engage the fallback.
            if (amountOut_ == 0) {
                revert();
            }
        } else if (venue == Venue.Bebop) {
            uint256 balanceTokenOutBefore = IERC20(tokenOut).balanceOf(
                address(this)
            );
            IERC20(tokenIn).forceApprove(BEBOP_ROUTER, amountIn);
            IBebopRouter(BEBOP_ROUTER).swap(
                tokenIn,
                tokenOut,
                amountIn,
                amountOutMin,
                deadline
            );

            // Prevent later transfers if token was partially pulled
            IERC20(tokenIn).forceApprove(BEBOP_ROUTER, 0);

            // Bebop's swap function has no `recipient` argument, it
            // delivers `tokenOut` to `msg.sender`, which here is this
            // router, so it is required to transfer the received tokens
            // to the actual recipient
            uint256 balanceTokenOut = IERC20(tokenOut).balanceOf(address(this));
            require(balanceTokenOut >= balanceTokenOutBefore, TokenOutBalanceDecreased());
            uint256 received = balanceTokenOut - balanceTokenOutBefore;
            if (received > 0 && recipient != address(this)) {
                IERC20(tokenOut).safeTransfer(recipient, received);
            }
        } else {
            revert UnknownVenue();
        }

        uint256 amountOut = IERC20(tokenOut).balanceOf(recipient) -
            prevTokenOutBalance;
        if (amountOut < amountOutMin) {
            revert();
        }

        return amountOut;
    }

    /// @notice Executes the fallback swap on Uniswap V3 with funds already held
    /// by this contract.
    /// @dev Assumes the router already holds `amountIn` of `tokenIn` — pulled
    /// once by `swap` before the try/catch. `UniV3Router.swapExactIn` only
    /// approves `fallbackSwapRouter` and executes the swap; it does not pull
    /// from `msg.sender`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param fee The Uniswap V3 pool fee tier (in hundredths of a bip).
    /// @param recipient The address that will receive `tokenOut`.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    function swapViaUniswapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint24 fee,
        address recipient
    ) private returns (uint256 amountOut) {
        amountOut = UniV3Router.swapExactIn(
            tokenIn,
            tokenOut,
            fee,
            amountIn,
            amountOutMin,
            recipient,
            fallbackSwapRouter
        );
        return amountOut;
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Queries each venue via try/catch. Fermi, Kipseli, and Bebop each
    /// expose their own on-chain quote (Kipseli via the dedicated
    /// `IKipseliQuoter.preSwapQuote` contract). The Fallback branch queries
    /// Uniswap V3's QuoterV2 at `uniswapFee`, which prices via revert-based
    /// simulation — so `quote` is not `view` and should be called via
    /// `eth_call` (staticcall) from off-chain.
    /// Reverts `NoQuotesAvailable` if every venue is skipped or reverts.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint24 uniswapFee
    ) public returns (uint256 bestQuote, Venue venue) {
        for (uint256 i = 0; i <= uint256(type(Venue).max); i++) {
            try
                this.quoteVenue(Venue(i), tokenIn, tokenOut, amount, uniswapFee)
            returns (uint256 amountOut) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    venue = Venue(i);
                }
            } catch {}
        }

        require(bestQuote > 0, NoQuotesAvailable());
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Forwards to the explicit-fee overload using
    /// `DEFAULT_FALLBACK_FEE` for the Uniswap V3 fallback branch.
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 bestQuote, Venue venue) {
        return quote(tokenIn, tokenOut, amount, DEFAULT_FALLBACK_FEE);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Queries the given venue's quote.
    /// `Venue.Fallback` is priced via Uniswap V3's QuoterV2 at `uniswapFee`, 
    /// which simulates via revert and makes this function non-`view`. Should be called via
    /// `eth_call` (staticcall) from off-chain. Reverts `UnknownVenue` if the
    /// given venue is unrecognized.
    function quoteVenue(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint24 uniswapFee
    ) public returns (uint256 amountOut) {
        if (venue == Venue.Fallback) {
            amountOut = UniV3Router.quoteExactIn(
                tokenIn,
                tokenOut,
                uniswapFee,
                amount,
                fallbackQuoter
            );
        } else if (venue == Venue.FermiSwap) {
            int256 amountInt256 = amount.toInt256();
            (, amountOut) = IFermiSwapper(FERMI_ROUTER).quoteAmounts(
                tokenIn,
                tokenOut,
                amountInt256
            );
        } else if (venue == Venue.Bebop) {
            amountOut = IBebopRouter(BEBOP_ROUTER).quote(
                tokenIn,
                tokenOut,
                amount
            );
        } else if (venue == Venue.Kipseli) {
            // Call the Kipseli quoter directly instead of 
            // going through the Kipseli swap wrapper to save gas
            amountOut = IKipseliQuoter(KIPSELI_QUOTER).preSwapQuote(
                tokenIn,
                amount,
                tokenOut,
                block.timestamp * 1000,
                address(0)
            );
        } else {
            revert UnknownVenue();
        }
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Forwards to the explicit-fee overload using
    /// `DEFAULT_FALLBACK_FEE` for the Uniswap V3 fallback branch.
    function quoteVenue(
        Venue venue,
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 amountOut) {
        return
            quoteVenue(venue, tokenIn, tokenOut, amount, DEFAULT_FALLBACK_FEE);
    }

    /// @dev Restricts UUPS upgrades to the contract owner set in `initialize`.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Pauses `swap`, blocking new swaps until `unpause` is called.
    /// @dev Owner-gated. Quote functions remain callable while paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses `swap`.
    function unpause() external onlyOwner {
        _unpause();
    }
}
