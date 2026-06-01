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
/// @notice Routes single-hop swaps to a propAMM and falls back through a fallback 
/// venue if the chosen venue reverts.
/// @dev Designed to live behind a UUPS proxy. The fallback path is wired at
/// initialization via `fallbackSwapRouter` and `fallbackQuoter`
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

    /// @notice Fallback venue address. 
    /// Owner-settable via `setFallbackSwapRouter`.
    address public fallbackSwapRouter;
    /// @notice Fallback venue address used to price the fallback route.
    /// Owner-settable via `setFallbackQuoter`.
    address public fallbackQuoter;
    /// @notice Fee for the fallback venue.
    uint24 public fallbackFee;
    /// @notice Per-pair Uniswap V3 fallback fee override, keyed by the sorted
    /// token pair (see `_pairKey`). A value of 0 means "unset" — the pair resolves
    /// to the global `fallbackFee`. Owner-settable via `setPairFee` / `setPairFees`.
    mapping(bytes32 pairKey => uint24 fee) private _pairFee;

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
    /// @notice Thrown when a fallback fee is invalid.
    error InvalidFallbackFee(uint24 fee);
    /// @notice Thrown when an address argument that must be non-zero is zero.
    error ZeroAddress();

    // `Swapped` is declared in IPropAMMRouter (part of the published interface)
    // and inherited here. The operational events below are implementation
    // detail and stay contract-local.

    /// @notice Emitted when the owner updates the fallback venue fee.
    /// @param oldFee The previous `fallbackFee`.
    /// @param newFee The new `fallbackFee`.
    event FallbackFeeUpdated(uint24 oldFee, uint24 newFee);
    /// @notice Emitted when the owner updates the fallback venue address.
    /// @param oldRouter The previous `fallbackSwapRouter`.
    /// @param newRouter The new `fallbackSwapRouter`.
    event FallbackSwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    /// @notice Emitted when the owner updates the fallback quoter address.
    /// @param oldQuoter The previous `fallbackQuoter`.
    /// @param newQuoter The new `fallbackQuoter`.
    event FallbackQuoterUpdated(address indexed oldQuoter, address indexed newQuoter);
    /// @notice Emitted when the owner rescues tokens stranded on the router.
    /// @param token The ERC-20 rescued.
    /// @param to The recipient of the rescued tokens.
    /// @param amount The amount transferred.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the router, pinning fallback venue address
    /// and setting the owner who controls future upgrades.
    /// @param fallbackSwapRouter_ Address of fallback router used
    /// to execute the fallback swap. Reverts `ZeroAddress` if zero — it also
    /// doubles as the fallback venue sentinel, so a zero value would corrupt
    /// venue identity (`_isVenue`, `_pickBestVenue`, `_coreSwap`).
    /// @param fallbackQuoter_ Address of the fallback quoter used to quote
    /// the fallback swap off-chain. Reverts `ZeroAddress` if zero.
    /// @param owner_ Initial owner of the proxy. Set directly here with no
    /// acceptance step — `Ownable2Step`'s two-step handoff only governs
    /// *subsequent* transfers via `transferOwnership` / `acceptOwnership`.
    /// Controls `_authorizeUpgrade` and any owner-gated administrative paths.
    /// Reverts if zero (enforced by `__Ownable_init`).
    function initialize(address fallbackSwapRouter_, address fallbackQuoter_, address owner_) public initializer {
        require(fallbackSwapRouter_ != address(0), ZeroAddress());
        require(fallbackQuoter_ != address(0), ZeroAddress());
        fallbackSwapRouter = fallbackSwapRouter_;
        fallbackQuoter = fallbackQuoter_;
        fallbackFee = 3000;
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Picks the best-quoting venue via `_pickBestVenue`, then executes
    /// through `_coreSwap`; a `fallbackSwapRouter` selection (the Uniswap
    /// fallback won, or no venue could quote) routes straight to the fallback venue.
    /// Reverts `QuoteBelowMinimum`
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
        // Fail fast before the on-chain best-venue quoting; `_coreSwap` re-checks
        // for the shared path also reached by `swapViaVenueV1`.
        require(block.timestamp <= deadline, Expired());
        (uint256 bestQuote, address venue) = _pickBestVenue(tokenIn, tokenOut, amountIn);
        require(bestQuote >= amountOutMin, QuoteBelowMinimum(amountOutMin, bestQuote));
        return _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Swaps via the `venue`. It must be a callable venue or the 
    /// fallback venue named by the `fallbackSwapRouter` address.
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

    /// @inheritdoc IPropAMMRouter
    /// @dev Requotes ONLY the caller-supplied `venues` on-chain via
    /// `_pickBestVenueFrom`, then executes the best through `_coreSwap`. As with
    /// `swapV1`, the fallback remains as the transparent safety net inside `_coreSwap`.
    /// Reverts `NoQuotesAvailable` if none of `venues` can be priced, and `QuoteBelowMinimum` 
    /// before pulling funds when the best quote across `venues` is under `amountOutMin`; 
    /// quotes are advisory, so `_coreSwap` re-checks `amountOutMin` against the delivered
    /// balance delta.
    function swapViaSelectedVenuesV1(
        address[] calldata venues,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) public whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        // Fail fast before the on-chain requote; `_coreSwap` re-checks deadline.
        require(block.timestamp <= deadline, Expired());
        (uint256 bestQuote, address venue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);
        // Reject when none of the selected venues could be priced (venue stays address(0)).
        require(venue != address(0), NoQuotesAvailable());
        require(bestQuote >= amountOutMin, QuoteBelowMinimum(amountOutMin, bestQuote));
        return _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
    }

    /// @notice Pulls funds once and executes a swap, attempting `venue` first
    /// and recovering via the fallback if it fails.
    /// @dev Shared core for `swapV1` and `swapViaVenueV1`; unguarded so the two
    /// public entrypoints can each apply `whenNotPaused`/`nonReentrant` without
    /// re-entering the guard through one another. 
    /// @param venue The propAMM to attempt first, or `fallbackSwapRouter`.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum acceptable amount of `tokenOut`.
    /// @param recipient The address that will receive `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @return amountOut The amount of `tokenOut` delivered to `recipient`.
    /// @return executedVenue The propAMM that filled the swap, or
    /// `fallbackSwapRouter` when the fallback ran.
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

        if (venue != fallbackSwapRouter) {
            try this._dispatchVenue(
                venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline, prevTokenOutBalance
            ) returns (
                uint256 amountOut_
            ) {
                _emitSwapped(venue, tokenIn, tokenOut, amountIn, amountOut_, recipient);
                return (amountOut_, venue);
            } catch {
                // Fall through to the Uniswap V3 fallback below.
            }
        }

        swapViaUniswapV3(tokenIn, tokenOut, amountIn, amountOutMin, recipient);
        amountOut = IERC20(tokenOut).balanceOf(recipient) - prevTokenOutBalance;
        require(amountOut >= amountOutMin, InsufficientOutput(amountOutMin, amountOut));
        _emitSwapped(fallbackSwapRouter, tokenIn, tokenOut, amountIn, amountOut, recipient);
        return (amountOut, fallbackSwapRouter);
    }

    /// @notice Logs a completed swap.
    /// @dev Wraps the `Swapped` emit so `_coreSwap` does not carry the event's
    /// arguments live on its (already param-heavy) stack at the emit site —
    /// avoids a stack-too-deep without enabling `viaIR`. `msg.sender` is read
    /// here and equals `_coreSwap`'s caller (and the entrypoint's), since
    /// internal calls preserve the message context.
    /// @param marketMaker The venue that filled, or `fallbackSwapRouter`. Placed
    /// first (not in `Swapped`'s field order) so the deepest `_coreSwap` local
    /// (`venue`) is read at the shallowest stack reach — another stack-too-deep
    /// guard. The helper maps params to the event's field order internally.
    /// @param tokenIn The token sold.
    /// @param tokenOut The token bought.
    /// @param amountIn The exact amount of `tokenIn` pulled from the caller.
    /// @param amountOut The amount of `tokenOut` delivered to `recipient`.
    /// @param recipient The address that received `tokenOut`.
    function _emitSwapped(
        address marketMaker,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    ) private {
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient, marketMaker);
    }

    /// @notice Executes a swap on a venue with funds already held by this contract.
    /// @dev Reverts `UnknownVenue` for non-whitelisted addresses, or
    /// bubbles up the underlying propAMM router's revert.
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
            revert InsufficientOutput(amountOutMin, amountOut);
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
    /// and fallback) and reverts `NoQuotesAvailable` if nothing could be priced.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        public
        returns (uint256 bestQuote, address venue)
    {
        (bestQuote, venue) = _pickBestVenue(tokenIn, tokenOut, amount);
        require(bestQuote > 0, NoQuotesAvailable());
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Dispatches by address across the propAMMs and the fallback.
    /// Reverts `UnknownVenue` for any other address.
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
        } else if (venue == fallbackSwapRouter) {
            amountOut = UniV3Router.quoteExactIn(tokenIn, tokenOut, fallbackFee, amount, fallbackQuoter);
        } else {
            revert UnknownVenue();
        }
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenueFrom`, considering ONLY `venues`, and
    /// reverts `NoQuotesAvailable` if none of them can be priced. Venues that
    /// revert while quoting — including non-whitelisted addresses, which
    /// `quoteVenueV1` rejects with `UnknownVenue` — are skipped, not surfaced.
    function quoteSelectedVenuesV1(address[] calldata venues, address tokenIn, address tokenOut, uint256 amountIn)
        public
        returns (uint256 bestAmountOut, address bestVenue)
    {
        (bestAmountOut, bestVenue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);
        require(bestAmountOut > 0, NoQuotesAvailable());
    }

    /// @notice Quotes the Uniswap V3 fallback for the pair at the current
    /// `fallbackFee` tier.
    /// @dev External so `_pickBestVenue` and `quoteV1` can wrap it in a
    /// `try/catch` (an internal library call can't be caught).
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` the Uniswap V3 swap would produce.
    function quoteUniswapV3(address tokenIn, address tokenOut, uint256 amount) external returns (uint256 amountOut) {
        return UniV3Router.quoteExactIn(tokenIn, tokenOut, fallbackFee, amount, fallbackQuoter);
    }

    /// @notice Finds the venue offering the best `tokenOut` for `amount` of
    /// `tokenIn` across the propAMMs and the fallback.
    /// @dev Each venue is queried in its own `try/catch` so a reverting venue is
    /// simply skipped. Returns `(0, fallbackSwapRouter)` when nothing can be
    /// priced — callers that need a hard failure (e.g. `quoteV1`) check the
    /// zero quote; `swapV1` instead lets `_coreSwap` route the
    /// `fallbackSwapRouter` to the fallback. The returned `venue` is one of the
    /// whitelisted venues.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return bestQuote The best `tokenOut` amount found across all venues.
    /// @return venue The venue that produced `bestQuote`.
    function _pickBestVenue(address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (uint256 bestQuote, address venue)
    {
        // A venue overtakes it only by quoting strictly more; if none do (or nothing can be priced at all),
        // `venue` stays `fallbackSwapRouter` and `_coreSwap` routes to fallback.
        venue = fallbackSwapRouter;

        address[3] memory venues = [FERMI_ROUTER, KIPSELI_PAMM, BEBOP_ROUTER];
        for (uint256 i = 0; i < venues.length; i++) {
            try this.quoteVenueV1(venues[i], tokenIn, tokenOut, amount) returns (uint256 amountOut) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    venue = venues[i];
                }
            } catch {}
        }

        // Uniswap V3 is the always-present fallback candidate: when it wins,
        // `venue` is `fallbackSwapRouter`, which `_coreSwap` (via `swapV1`)
        // treats as the Uniswap fallback. Callers may also name that address
        // directly through `swapViaVenueV1` / `quoteVenueV1`.
        try this.quoteUniswapV3(tokenIn, tokenOut, amount) returns (uint256 amountOut) {
            if (amountOut > bestQuote) {
                bestQuote = amountOut;
                venue = fallbackSwapRouter;
            }
        } catch {}
    }

    /// @notice Finds the venue offering the best `tokenOut` for `amount` of
    /// `tokenIn` among a caller-supplied set of venues.
    /// @dev Quotes ONLY the provided `venues` (each via `this.quoteVenueV1` in
    /// its own `try/catch`), so a venue that reverts — including a
    /// non-whitelisted address, which `quoteVenueV1` rejects with `UnknownVenue`
    /// — is simply skipped. Unlike `_pickBestVenue`, it does NOT seed or
    /// auto-include the Uniswap fallback: the returned `venue` is `address(0)`
    /// when none of the supplied venues can be priced. The Uniswap fallback
    /// still applies at execution time via `_coreSwap` (the transparent safety
    /// net); it is just not a selection candidate here unless the caller lists
    /// the `fallbackSwapRouter` address explicitly.
    /// @param venues The venues to consider — a subset the caller chose.
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return bestQuote The best `tokenOut` amount found across `venues`, or 0.
    /// @return venue The venue that produced `bestQuote`, or `address(0)` if none.
    function _pickBestVenueFrom(address[] calldata venues, address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (uint256 bestQuote, address venue)
    {
        for (uint256 i = 0; i < venues.length; i++) {
            try this.quoteVenueV1(venues[i], tokenIn, tokenOut, amount) returns (uint256 amountOut) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    venue = venues[i];
                }
            } catch {}
        }
    }

    /// @notice Returns whether `venue` is a venue a caller may name explicitly in
    /// `quoteVenueV1` / `swapViaVenueV1`.
    function _isVenue(address venue) private view returns (bool) {
        if (venue == address(0)) return false;
        return venue == FERMI_ROUTER || venue == KIPSELI_PAMM || venue == BEBOP_ROUTER || venue == fallbackSwapRouter;
    }

    /// @dev Canonical key for a token pair, order-independent. Uniswap V3 pools
    /// are symmetric (one pool, `token0 < token1`, serves both directions), so
    /// {A,B} and {B,A} share one entry.
    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(a, b));
    }

    /// @notice Resolves the Uniswap V3 fallback fee for a pair: the per-pair
    /// override if set, otherwise the global `fallbackFee`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @return fee The effective fee tier in hundredths of a bip.
    function _resolveFee(address tokenIn, address tokenOut) private view returns (uint24 fee) {
        fee = _pairFee[_pairKey(tokenIn, tokenOut)];
        if (fee == 0) fee = fallbackFee;
    }

    /// @dev Restricts UUPS upgrades to the contract owner set in `initialize`.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Sets the fallback fee used by the fallback route.
    /// @dev Owner-gated. Lets the deepest pool for the traded pairs be selected
    /// without a contract upgrade.
    /// @param fee in hundredths of a bip (e.g. `3000` for 0.30%).
    function setFallbackFee(uint24 fee) external onlyOwner {
        require(fee != 0 && fee < 1_000_000, InvalidFallbackFee(fee));
        emit FallbackFeeUpdated(fallbackFee, fee);
        fallbackFee = fee;
    }

    /// @notice Returns the raw per-pair fee override for a pair (0 if unset).
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token of the pair.
    function getPairFee(address tokenA, address tokenB) external view returns (uint24) {
        return _pairFee[_pairKey(tokenA, tokenB)];
    }

    /// @notice Returns the effective Uniswap V3 fallback tier the router will use
    /// for a pair: the per-pair override if set, otherwise the global `fallbackFee`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    function resolvedFee(address tokenIn, address tokenOut) external view returns (uint24) {
        return _resolveFee(tokenIn, tokenOut);
    }

    /// @notice Repoints the address used by the fallback route.
    /// @dev Owner-gated. Lets a new SwapRouter deployment be adopted without a
    /// contract upgrade. Reverts `ZeroAddress` if zero — this address also
    /// identifies the fallback venue (`_isVenue`, `_pickBestVenue`, `_coreSwap`),
    /// so a zero value would corrupt venue identity. Note that `executedVenue`
    /// values observed off-chain are only meaningful relative to the router's
    /// configuration at the time of the swap.
    /// @param newRouter Address of thew new router.
    function setFallbackSwapRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), ZeroAddress());
        emit FallbackSwapRouterUpdated(fallbackSwapRouter, newRouter);
        fallbackSwapRouter = newRouter;
    }

    /// @notice Repoints the fallback quoter used to price the fallback route.
    /// @dev Owner-gated. Reverts `ZeroAddress` if zero.
    /// @param newQuoter Address of the new fallback quoter.
    function setFallbackQuoter(address newQuoter) external onlyOwner {
        require(newQuoter != address(0), ZeroAddress());
        emit FallbackQuoterUpdated(fallbackQuoter, newQuoter);
        fallbackQuoter = newQuoter;
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

    /// @notice Rescues ERC-20 tokens stranded on the router.
    /// @dev Owner-gated. The router holds no balance between swaps, so any
    /// standing balance is unintended (mis-sent funds, fee-on-transfer dust, or
    /// a partial-pull remainder). Not `nonReentrant`: it must stay callable and
    /// it moves no in-flight swap funds — swaps are atomic and `nonReentrant`.
    /// @param token The ERC-20 to rescue.
    /// @param to The recipient of the rescued tokens.
    /// @param amount The amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), ZeroAddress());
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }
}
