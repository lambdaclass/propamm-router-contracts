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
/// Bebop) and falls back to Uniswap V3 if the chosen proprietary venue reverts.
/// @dev Designed to live behind a UUPS proxy. The fallback path is wired at
/// initialization via `fallbackSwapRouter` (SwapRouter02) and `fallbackQuoter`
/// (QuoterV2); proprietary venue addresses are hardcoded as constants. Venues
/// are identified by address: the whitelist of venues a caller may name
/// explicitly is exactly the three proprietary AMMs (see `_isVenue`). Uniswap V3
/// is never named directly — it is folded into `quoteV1` as a baseline price and
/// is reached automatically (best-quote selection in `swapV1`, or as the failure
/// fallback). The Uniswap fee tier is the owner-settable `fallbackFee`, so
/// callers never pass one. The owner authorized in `initialize` controls
/// upgrades via `_authorizeUpgrade`.
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
    /// @notice Uniswap V3 pool fee tier (in hundredths of a bip) used for the
    /// Uniswap fallback quote and swap. `3000` = 0.30% by default; the owner can
    /// retune it via `setFallbackFee` without a contract upgrade. Appended after
    /// the existing storage variables to keep the UUPS layout upgrade-safe.
    uint24 public fallbackFee;

    /// @notice Thrown when `_dispatchVenue` is called by anyone other than this
    /// contract itself, i.e. outside of the `try`-wrapped self-call made by
    /// `_coreSwap`.
    error OnlySelf();
    /// @notice Thrown when `venue` is not one of the whitelisted proprietary AMMs.
    error UnknownVenue();
    /// @notice Thrown when a swap cannot deliver at least `amountOutMin` of
    /// `tokenOut` to `recipient`.
    /// @param expectedAmount The minimum acceptable amount of `tokenOut` (i.e.
    /// the caller's `amountOutMin`).
    /// @param receivedAmount The actual amount of `tokenOut` delivered to
    /// `recipient`, measured as a balance delta against the pre-swap snapshot.
    error InsufficientOutput(uint256 expectedAmount, uint256 receivedAmount);
    /// @notice Thrown by `swapV1` when the best quote across all venues is below
    /// `amountOutMin`, rejecting the swap before any funds are pulled. Distinct
    /// from `InsufficientOutput`, which signals a shortfall measured *after*
    /// execution.
    /// @param amountOutMin The caller's minimum acceptable amount of `tokenOut`.
    /// @param bestQuote The best `tokenOut` amount any venue quoted.
    error QuoteBelowMinimum(uint256 amountOutMin, uint256 bestQuote);
    /// @notice Thrown when a swap is invoked after its `deadline`.
    error Expired();
    /// @notice Thrown when no venue can produce a quote for the requested pair
    /// and amount.
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
    function initialize(address fallbackSwapRouter_, address fallbackQuoter_, address owner_) public initializer {
        fallbackSwapRouter = fallbackSwapRouter_;
        fallbackQuoter = fallbackQuoter_;
        fallbackFee = 3000;
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Picks the best-quoting venue via `_pickBestVenue`, then executes
    /// through `_coreSwap`; an `address(0)` selection (no venue could quote)
    /// routes straight to the Uniswap fallback. Reverts `QuoteBelowMinimum`
    /// before pulling funds when the best quote is under `amountOutMin`. Quotes
    /// are advisory, so `_coreSwap` re-checks `amountOutMin` against the
    /// delivered balance delta.
    function swapV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        (uint256 bestQuote, address venue) = _pickBestVenue(tokenIn, tokenOut, amountIn);
        require(bestQuote >= amountOutMin, QuoteBelowMinimum(amountOutMin, bestQuote));
        return _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev `venue` must be a whitelisted proprietary AMM (`_isVenue`); Uniswap
    /// V3 cannot be named here and is only reached as the failure fallback
    /// inside `_coreSwap`.
    function swapViaVenueV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) public whenNotPaused nonReentrant returns (uint256 amountOut) {
        require(_isVenue(venue), UnknownVenue());
        (amountOut,) = _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
    }

    /// @notice Pulls funds once and executes a swap, attempting `venue` first
    /// and recovering on Uniswap V3 if it fails.
    /// @dev Shared core for `swapV1` and `swapViaVenueV1`; unguarded so the two
    /// public entrypoints can each apply `whenNotPaused`/`nonReentrant` without
    /// re-entering the guard through one another. Pulls `amountIn` of `tokenIn`
    /// from `msg.sender`, snapshots `recipient`'s `tokenOut` balance, then:
    /// for a proprietary `venue`, wraps the venue call in `try this._dispatchVenue`
    /// so a revert (including an under-fill, which `_dispatchVenue` turns into a
    /// revert) is caught and recovered on Uniswap V3; for `address(0)` (no
    /// proprietary venue selected, or the Uniswap baseline was best) it runs
    /// Uniswap V3 directly. The external self-call is intentional: only an
    /// external call produces a catchable frame and rolls back the venue's
    /// `forceApprove`. The Uniswap branch re-measures the delivered delta and
    /// enforces `amountOutMin` to defend against an under-delivering router.
    /// @param venue The proprietary AMM to attempt first, or `address(0)` to go
    /// straight to the Uniswap V3 fallback.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` delivered to `recipient`.
    /// @return executedVenue The proprietary AMM that filled the swap, or
    /// `address(0)` when the Uniswap V3 fallback ran.
    function _coreSwap(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amountOut, address executedVenue) {
        require(block.timestamp <= deadline, Expired());
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 prevTokenOutBalance = IERC20(tokenOut).balanceOf(recipient);

        if (venue != address(0)) {
            try this._dispatchVenue(
                venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, prevTokenOutBalance
            ) returns (
                uint256 amountOut_
            ) {
                return (amountOut_, venue);
            } catch {
                // Fall through to the Uniswap V3 fallback below.
            }
        }

        swapViaUniswapV3(tokenIn, tokenOut, amountIn, amountOutMin, recipient);
        amountOut = IERC20(tokenOut).balanceOf(recipient) - prevTokenOutBalance;
        require(amountOut >= amountOutMin, InsufficientOutput(amountOutMin, amountOut));
        return (amountOut, address(0));
    }

    /// @notice Executes a swap on a proprietary venue with funds already held by
    /// this contract.
    /// @dev External (not internal) because `_coreSwap` invokes it as
    /// `this._dispatchVenue(...)` to wrap the venue call in a try/catch — only
    /// external calls produce a catchable frame, and a revert there also rolls
    /// back the per-venue `forceApprove` issued below. The router must already
    /// hold `amountIn` of `tokenIn`; this function approves the selected venue
    /// for `amountIn` and the venue pulls during its own swap. Gated on
    /// `msg.sender == address(this)` so only the self-call from `_coreSwap` can
    /// enter (reverts `OnlySelf` otherwise). After the venue call, measures the
    /// delivered delta on `recipient` and reverts if it is below `amountOutMin`
    /// — by reverting (rather than returning a thin amount) the under-fill is
    /// caught by the outer try/catch in `_coreSwap` and triggers the Uniswap V3
    /// fallback. Reverts `UnknownVenue` for non-whitelisted addresses, or
    /// bubbles up the underlying proprietary router's revert.
    /// @param venue The proprietary venue to route the swap through.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`; an
    /// under-fill below this triggers a revert here so the fallback engages.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid;
    /// only honored by venues that enforce it (e.g. Bebop).
    /// @param prevTokenOutBalance `recipient`'s `tokenOut` balance snapshotted
    /// by `_coreSwap` before this call, passed through so the delivered delta
    /// can be computed without re-reading the pre-balance.
    /// @return amountOut The amount of `tokenOut` delivered to `recipient`,
    /// measured as the balance delta against `prevTokenOutBalance`.
    function _dispatchVenue(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        uint256 prevTokenOutBalance
    ) external returns (uint256 amountOut) {
        require(msg.sender == address(this), OnlySelf());

        if (venue == FERMI_ROUTER) {
            IERC20(tokenIn).forceApprove(FERMI_ROUTER, amountIn);
            int256 _amountIn = amountIn.toInt256();
            IFermiSwapper(FERMI_ROUTER).fermiSwapWithAllowances(tokenIn, tokenOut, _amountIn, amountOutMin, recipient);

            // Prevent later transfers if token was partially pulled
            IERC20(tokenIn).forceApprove(FERMI_ROUTER, 0);
        } else if (venue == KIPSELI_PAMM) {
            IERC20(tokenIn).safeTransfer(KIPSELI_PAMM, amountIn);
            uint256 amountOut_ = IKipseliPAMM(KIPSELI_PAMM).swap(tokenIn, amountIn, tokenOut, recipient);

            // Kipseli signals failure by returning 0 and keeping `tokenIn`; revert
            // to roll back its transfer and let the catch arm engage the fallback.
            if (amountOut_ == 0) {
                revert();
            }
        } else if (venue == BEBOP_ROUTER) {
            uint256 balanceTokenOutBefore = IERC20(tokenOut).balanceOf(address(this));
            IERC20(tokenIn).forceApprove(BEBOP_ROUTER, amountIn);
            IBebopRouter(BEBOP_ROUTER).swap(tokenIn, tokenOut, amountIn, amountOutMin, deadline);

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

        amountOut = IERC20(tokenOut).balanceOf(recipient) - prevTokenOutBalance;
        if (amountOut < amountOutMin) {
            revert();
        }

        return amountOut;
    }

    /// @notice Executes the fallback swap on Uniswap V3 with funds already held
    /// by this contract.
    /// @dev Assumes the router already holds `amountIn` of `tokenIn` — pulled
    /// once by `_coreSwap` before the try/catch. Uses the owner-set `fallbackFee`
    /// pool tier. `UniV3Router.swapExactIn` only approves `fallbackSwapRouter`
    /// and executes the swap; it does not pull from `msg.sender`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    /// @return amountOut The amount of `tokenOut` received by `recipient`.
    function swapViaUniswapV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) private returns (uint256 amountOut) {
        amountOut = UniV3Router.swapExactIn(
            tokenIn, tokenOut, fallbackFee, amountIn, amountOutMin, recipient, fallbackSwapRouter
        );
        return amountOut;
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenue` (which compares the proprietary AMMs
    /// and the Uniswap V3 baseline) and reverts `NoQuotesAvailable` if nothing
    /// could be priced.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        public
        returns (uint256 bestQuote, address venue)
    {
        (bestQuote, venue) = _pickBestVenue(tokenIn, tokenOut, amount);
        require(bestQuote > 0, NoQuotesAvailable());
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Dispatches by address across the whitelisted proprietary AMMs only.
    /// Kipseli is quoted via the dedicated `IKipseliQuoter.preSwapQuote` contract
    /// rather than the swap wrapper to save gas. Uniswap V3 is intentionally not
    /// quotable here — it is only surfaced through `quoteV1`. Reverts
    /// `UnknownVenue` for any non-whitelisted address.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        public
        returns (uint256 amountOut)
    {
        if (venue == FERMI_ROUTER) {
            int256 amountInt256 = amount.toInt256();
            (, amountOut) = IFermiSwapper(FERMI_ROUTER).quoteAmounts(tokenIn, tokenOut, amountInt256);
        } else if (venue == KIPSELI_PAMM) {
            amountOut = IKipseliQuoter(KIPSELI_QUOTER)
                .preSwapQuote(tokenIn, amount, tokenOut, block.timestamp * 1000, address(0));
        } else if (venue == BEBOP_ROUTER) {
            amountOut = IBebopRouter(BEBOP_ROUTER).quote(tokenIn, tokenOut, amount);
        } else {
            revert UnknownVenue();
        }
    }

    /// @notice Quotes the Uniswap V3 baseline for the pair at the current
    /// `fallbackFee` tier.
    /// @dev External so `_pickBestVenue` and `quoteV1` can wrap it in a
    /// `try/catch` (an internal library call can't be caught). Not `view`:
    /// QuoterV2 prices via revert-based simulation. Call off-chain via
    /// `eth_call` (staticcall).
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` the Uniswap V3 swap would produce.
    function quoteUniswapV3(address tokenIn, address tokenOut, uint256 amount) external returns (uint256 amountOut) {
        return UniV3Router.quoteExactIn(tokenIn, tokenOut, fallbackFee, amount, fallbackQuoter);
    }

    /// @notice Finds the venue offering the best `tokenOut` for `amount` of
    /// `tokenIn` across the proprietary AMMs and the Uniswap V3 baseline.
    /// @dev Each venue is queried in its own `try/catch` so a reverting venue is
    /// simply skipped. Returns `(0, address(0))` when nothing can be priced —
    /// callers that need a hard failure (e.g. `quoteV1`) check for that;
    /// `swapV1` instead lets `_coreSwap` route the `address(0)` case to Uniswap.
    /// Every non-zero `venue` returned here is one of the whitelisted
    /// proprietary AMMs, so it is always accepted by `swapViaVenueV1` /
    /// `quoteVenueV1`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return bestQuote The best `tokenOut` amount found across all venues.
    /// @return venue The proprietary AMM that produced `bestQuote`, or
    /// `address(0)` if the Uniswap V3 baseline won (or nothing could be priced).
    function _pickBestVenue(address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (uint256 bestQuote, address venue)
    {
        address[3] memory venues = [FERMI_ROUTER, KIPSELI_PAMM, BEBOP_ROUTER];
        for (uint256 i = 0; i < venues.length; i++) {
            try this.quoteVenueV1(venues[i], tokenIn, tokenOut, amount) returns (uint256 amountOut) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    venue = venues[i];
                }
            } catch {}
        }

        // Uniswap V3 is a baseline candidate but not a nameable venue: when it
        // wins, `venue` stays `address(0)` so the result is never an address
        // that `swapViaVenueV1` / `quoteVenueV1` would reject.
        try this.quoteUniswapV3(tokenIn, tokenOut, amount) returns (uint256 amountOut) {
            if (amountOut > bestQuote) {
                bestQuote = amountOut;
                venue = address(0);
            }
        } catch {}
    }

    /// @notice Returns whether `venue` is a whitelisted proprietary AMM that a
    /// caller may name explicitly in `quoteVenueV1` / `swapViaVenueV1`.
    /// @dev The whitelist is the three hardcoded proprietary routers. Uniswap V3
    /// is deliberately excluded — it is reachable only via `swapV1`'s best-quote
    /// selection or as the failure fallback.
    function _isVenue(address venue) private pure returns (bool) {
        return venue == FERMI_ROUTER || venue == KIPSELI_PAMM || venue == BEBOP_ROUTER;
    }

    /// @dev Restricts UUPS upgrades to the contract owner set in `initialize`.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Sets the Uniswap V3 pool fee tier used by the fallback route.
    /// @dev Owner-gated. Lets the deepest pool for the traded pairs be selected
    /// without a contract upgrade.
    /// @param fee The Uniswap V3 fee tier in hundredths of a bip (e.g. `3000`
    /// for 0.30%).
    function setFallbackFee(uint24 fee) external onlyOwner {
        fallbackFee = fee;
    }

    /// @notice Pauses swaps, blocking new swaps until `unpause` is called.
    /// @dev Owner-gated. Quote functions remain callable while paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses swaps.
    function unpause() external onlyOwner {
        _unpause();
    }
}
