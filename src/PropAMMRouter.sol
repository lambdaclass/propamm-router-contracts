// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "./interfaces/IPropAMMRouter.sol";
import {IPropAMM} from "./interfaces/IPropAMM.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {FERMI_ROUTER, IFermiSwapper} from "./interfaces/IFermiSwapper.sol";
import {BEBOP_ROUTER, IBebopRouter} from "./interfaces/IBebopRouter.sol";
import {UniV3Router} from "./libraries/UniV3Router.sol";
import {FrontendFees} from "./libraries/FrontendFees.sol";
import {ETH_SENTINEL, USDC, USDT, WETH} from "./libraries/Constants.sol";
import "./libraries/Errors.sol";
import "./libraries/Events.sol";

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
    AccessManagedUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Fallback venue address.
    /// Settable (access-controlled) via `setFallbackSwapRouter`.
    address public fallbackSwapRouter;
    /// @notice Fallback venue address used to price the fallback route.
    /// Settable (access-controlled) via `setFallbackQuoter`.
    address public fallbackQuoter;
    /// @notice Fee for the fallback venue.
    uint24 public fallbackFee;
    /// @notice Per-pair Uniswap V3 fallback fee override, keyed by the sorted
    /// token pair (see `_pairKey`). A value of 0 means "unset" — the pair resolves
    /// to the global `fallbackFee`. Settable (access-controlled) via `setPairFee` / `setPairFees`.
    mapping(bytes32 pairKey => uint24 fee) private _pairFee;
    /// @notice Whitelist of propAMM venues the router may route through. This is
    /// the authoritative check for whether an address may be used as a propAMM
    /// (`_isVenue`, `quoteVenueV1`, `_dispatchVenue`): a venue de-listed here is
    /// skipped by every selection path and rejected on every explicit path. As an
    /// enumerable set it is also the source of candidates iterated by
    /// `_pickBestVenue`, so a venue added via `addVenue` is automatically
    /// considered by `swapV1` / `quoteV1` without a contract upgrade. The Uniswap
    /// V3 fallback (`fallbackSwapRouter`) is the always-available safety net and is
    /// intentionally NOT a member — it is accepted independently of this set.
    /// Seeded with the known propAMMs in `initialize` and managed (access-controlled)
    /// via `addVenue` / `removeVenue`, so its size (and thus the
    /// `_pickBestVenue` loop bound) is trusted to stay small.
    /// @dev Declared last to keep the upgradeable storage layout append-only.
    EnumerableSet.AddressSet private _whitelistedVenues;

    //------------//
    // Initialize //
    //------------//

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the router, pinning the fallback venue address
    /// and the `AccessManager` authority that governs administrative actions.
    /// @param fallbackSwapRouter_ Address of fallback router used
    /// to execute the fallback swap. Reverts `ZeroAddress` if zero — it also
    /// doubles as the fallback venue sentinel, so a zero value would corrupt
    /// venue identity (`_isVenue`, `_pickBestVenue`, `_coreSwap`).
    /// @param fallbackQuoter_ Address of the fallback quoter used to quote
    /// the fallback swap off-chain. Reverts `ZeroAddress` if zero.
    /// @param authority_ The `AccessManager` instance that governs every
    /// `restricted` administrative entrypoint: `_authorizeUpgrade` (UUPS
    /// upgrades), the fallback and pair-fee setters, the venue whitelist
    /// (`addVenue` / `removeVenue`), `pause`/`unpause`, and `rescueTokens`.
    /// Which role may call each selector, the per-role execution delays, and the
    /// instant guardian pause are all configured on the manager itself — not
    /// here — so the router stays policy-agnostic. Reverts `ZeroAddress` if zero;
    /// `__AccessManaged_init` does not validate it and a zero authority would
    /// leave the contract permanently unmanageable.
    function initialize(address fallbackSwapRouter_, address fallbackQuoter_, address authority_) public initializer {
        require(fallbackSwapRouter_ != address(0), ZeroAddress());
        require(fallbackQuoter_ != address(0), ZeroAddress());
        require(authority_ != address(0), ZeroAddress());

        fallbackSwapRouter = fallbackSwapRouter_;
        fallbackQuoter = fallbackQuoter_;
        fallbackFee = 3000;

        _seedDefaultPairFees();

        _addVenue(FERMI_ROUTER);
        _addVenue(BEBOP_ROUTER);
        _addVenue(0x71e790dd841c8A9061487cb3E78C288E75cE0B3d); // Kipseli

        __AccessManaged_init(authority_);
        __Pausable_init();
    }

    /// @notice Seeds the deep mainnet Uniswap V3 fallback fee tiers so a
    /// from-scratch deploy is configured without a separate owner-run seeding step.
    /// @dev Routes through `_setPairFee`, so each seeded pair clears the same
    /// validation and emits `PairFeeUpdated(tokenA, tokenB, 0, fee)` — an indexer
    /// sees the initial config exactly as if the owner had set it. Tiers are the
    /// deepest live mainnet pools: stable/stable at 0.01%, ETH/stable at 0.05%.
    function _seedDefaultPairFees() private {
        _setPairFee(USDT, USDC, 100); // stablecoin pair — deepest at 0.01%
        _setPairFee(USDT, WETH, 500); // ETH/stable — deepest at 0.05%
        _setPairFee(USDC, WETH, 500); // ETH/stable — deepest at 0.05%
    }

    //------//
    // Swap //
    //------//

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
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        (uint256 bestQuote, address venue) = _pickBestVenue(tokenIn, tokenOut, amountIn);
        require(bestQuote >= amountOutMin, QuoteBelowMinimum(amountOutMin, bestQuote));

        (amountOut, executedVenue) = _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Validates `fee`, grosses up the net `amountOutMin` so the user still nets
    /// at least their minimum, routes the swap to this contract, then forwards the fee
    /// and the net. Emits `Swapped` with the net amount and the real `recipient`.
    /// `whenNotPaused`/`nonReentrant` like `swapV1`.
    function swapWithFeeV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        FrontendFees._validateFee(fee);

        uint256 grossMin = FrontendFees._grossUp(amountOutMin, fee.bps);
        (, address venue) = _pickBestVenue(tokenIn, tokenOut, amountIn);

        uint256 delivered;
        (delivered, executedVenue) = _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = FrontendFees._skimAndDisburse(tokenOut, delivered, fee, recipient);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
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
    ) public payable whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        require(_isVenue(venue), UnknownVenue());

        (amountOut, executedVenue) = _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Like `swapViaVenueV1` plus the fee skim; the underlying
    /// swap is routed to this contract, then fee + net are forwarded.
    /// Reverts `UnknownVenue` if `venue` is neither a whitelisted propAMM
    /// nor the fallback address.
    function swapViaVenueWithFeeV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        FrontendFees._validateFee(fee);
        require(_isVenue(venue), UnknownVenue());

        uint256 grossMin = FrontendFees._grossUp(amountOutMin, fee.bps);
        (uint256 delivered, address executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = FrontendFees._skimAndDisburse(tokenOut, delivered, fee, recipient);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Requotes ONLY the caller-supplied `venues` on-chain via
    /// `_pickBestVenueFrom` and attempts to swap via the best-quoting one;
    /// quotes are advisory, so `amountOutMin` is enforced at execution by
    /// `_coreSwap`. When no venue can be priced (or the attempted venue fails
    /// to fill), `_coreSwap` falls back to swapping via Uniswap V3.
    function swapViaSelectedVenuesV1(
        address[] calldata venues,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) public payable whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        (, address venue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);

        (amountOut, executedVenue) = _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Like `swapViaSelectedVenuesV1` plus the fee skim; requotes
    /// only `venues`, grosses up the net min, routes the swap to this contract, then forwards
    /// fee + net.
    function swapViaSelectedVenuesWithFeeV1(
        address[] calldata venues,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        FrontendFees._validateFee(fee);

        uint256 grossMin = FrontendFees._grossUp(amountOutMin, fee.bps);
        (, address venue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);

        uint256 delivered;
        (delivered, executedVenue) = _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = FrontendFees._skimAndDisburse(tokenOut, delivered, fee, recipient);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Pulls funds once and executes a swap, attempting `venue` first
    /// and recovering via the fallback if it fails.
    /// @dev Shared core for all the public swap entrypoints; unguarded so each
    /// of them can apply `whenNotPaused`/`nonReentrant` without
    /// re-entering the guard through one another. The `Swapped` event is emitted
    /// by the calling entrypoint (not here) so the fee entrypoints can log the
    /// net amount and real recipient.
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

        address tokenIn_ = tokenIn;
        if (tokenIn == ETH_SENTINEL) {
            // If tokenIn is ETH, we wrap it and use WETH as the tokenIn for swap
            require(msg.value == amountIn, InvalidValue(amountIn, msg.value));
            IWETH(WETH).deposit{value: msg.value}();
            tokenIn_ = WETH;
        } else {
            require(msg.value == 0, InvalidValue(0, msg.value));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        address tokenOut_ = tokenOut;
        address recipient_ = recipient;
        if (tokenOut == ETH_SENTINEL) {
            tokenOut_ = WETH;
            recipient_ = address(this);
        }

        require(tokenIn_ != tokenOut_, IdenticalTokens());

        uint256 prevTokenOutBalance = IERC20(tokenOut_).balanceOf(recipient_);

        if (venue != fallbackSwapRouter) {
            try this._dispatchVenue(
                venue, tokenIn_, tokenOut_, amountIn, amountOutMin, recipient_, deadline, prevTokenOutBalance
            ) returns (
                uint256 amountOut_
            ) {
                if (tokenOut == ETH_SENTINEL) {
                    _sendWrappedETH(recipient, amountOut_);
                }

                return (amountOut_, venue);
            } catch {
                // Fall through to the Uniswap V3 fallback below.
            }
        }

        UniV3Router.swapExactIn(
            tokenIn_,
            tokenOut_,
            resolvedFee(tokenIn_, tokenOut_),
            amountIn,
            amountOutMin,
            recipient_,
            fallbackSwapRouter
        );
        amountOut = IERC20(tokenOut_).balanceOf(recipient_) - prevTokenOutBalance;
        require(amountOut >= amountOutMin, InsufficientOutput(amountOutMin, amountOut));

        if (tokenOut == ETH_SENTINEL) {
            _sendWrappedETH(recipient, amountOut);
        }

        return (amountOut, fallbackSwapRouter);
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
        // `_coreSwap` only reaches here for a non-fallback venue; it must be a
        // whitelisted propAMM. A de-listed venue reverts so the catch arm in
        // `_coreSwap` engages the Uniswap fallback.
        require(isWhitelistedVenue(venue), UnknownVenue());

        if (venue == FERMI_ROUTER) {
            IERC20(tokenIn).forceApprove(FERMI_ROUTER, amountIn);
            int256 _amountIn = amountIn.toInt256();
            IFermiSwapper(FERMI_ROUTER).fermiSwapWithAllowances(tokenIn, tokenOut, _amountIn, amountOutMin, recipient);

            // Prevent later transfers if token was partially pulled
            IERC20(tokenIn).forceApprove(FERMI_ROUTER, 0);
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
            // Any other whitelisted venue speaks the common `IPropAMM` interface.
            // Push-payment model: transfer `tokenIn` first, then let the venue
            // consume it and deliver `tokenOut` straight to `recipient`. A revert
            // (or an under-delivery caught below) rolls back this transfer via the
            // `_coreSwap` self-call `try/catch` and engages the Uniswap fallback.
            IERC20(tokenIn).safeTransfer(venue, amountIn);
            IPropAMM(venue).swap(tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        }

        amountOut = IERC20(tokenOut).balanceOf(recipient) - prevTokenOutBalance;
        require(amountOut >= amountOutMin, InsufficientOutput(amountOutMin, amountOut));

        return amountOut;
    }

    /// @notice Unwrap `amount` WETH into ETH and send it to `to`.
    /// @dev Reverts `ETHTransferFailed` if the transfer failed.
    /// @param to Account that will receive the ETH.
    /// @param amount Amount of WETH to unwrap and send.
    function _sendWrappedETH(address to, uint256 amount) private {
        IWETH(WETH).withdraw(amount);
        if (to != address(this)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, ETHTransferFailed());
        }
    }

    /// @notice Logs a completed swap.
    /// @dev Wraps the `Swapped` emit so the calling entrypoint does not carry
    /// the event's arguments live on its (already param-heavy) stack at the
    /// emit site — avoids a stack-too-deep without enabling `viaIR`. Called
    /// from the public swap entrypoints after `_coreSwap` returns. `msg.sender`
    /// is read here and equals the entrypoint's caller, since internal calls
    /// preserve the message context.
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

    // We don't accept plain transfers from accounts. They should use `swap*` instead.
    // receive() is needed though, to receive the withdrawal ETH from WETH.
    receive() external payable {
        require(msg.sender == WETH, UnexpectedETHSender());
    }

    //-------//
    // Quote //
    //-------//

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenue` (which compares the proprietary AMMs
    /// and fallback) and reverts `NoQuotesAvailable` if nothing could be priced.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        public
        returns (uint256 bestQuote, address venue)
    {
        if (tokenIn == ETH_SENTINEL) {
            tokenIn = WETH;
        }
        if (tokenOut == ETH_SENTINEL) {
            tokenOut = WETH;
        }

        (bestQuote, venue) = _pickBestVenue(tokenIn, tokenOut, amount);
        require(bestQuote > 0, NoQuotesAvailable());
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Gates on `_isVenue` (a whitelisted propAMM or the fallback),
    /// reverting `UnknownVenue` otherwise. Prices `venue` through
    /// `_dispatchQuoteVenue` (which resolves the fallback address to the Uniswap
    /// V3 route); if the venue cannot be priced (its quoter reverts, or it does
    /// not implement the expected interface), the call does NOT surface the
    /// revert — it gracefully falls back to the public venue, returning the
    /// Uniswap quote and `fallbackSwapRouter` as `quotedVenue`. It only reverts
    /// when the public venue itself cannot be priced either. The selection
    /// helpers (`_pickBestVenue`, `_pickBestVenueFrom`) deliberately bypass this
    /// graceful fallback by calling `_dispatchQuoteVenue` directly, so a failing
    /// venue is skipped rather than silently re-quoted as the fallback.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        public
        returns (uint256 amountOut, address quotedVenue)
    {
        require(_isVenue(venue), UnknownVenue());

        if (tokenIn == ETH_SENTINEL) {
            tokenIn = WETH;
        }
        if (tokenOut == ETH_SENTINEL) {
            tokenOut = WETH;
        }

        // Quote the venue (the fallback included), and if it cannot be priced
        // gracefully fall back to the public venue, reporting `fallbackSwapRouter`.
        try this._dispatchQuoteVenue(venue, tokenIn, tokenOut, amount) returns (uint256 out) {
            return (out, venue);
        } catch {
            return (quoteUniswapV3(tokenIn, tokenOut, amount), fallbackSwapRouter);
        }
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenueFrom`, considering ONLY `venues`. Venues
    /// that revert while quoting — including non-whitelisted addresses, which
    /// `_dispatchQuoteVenue` rejects with `UnknownVenue` — are skipped, not surfaced.
    /// When none of `venues` can be priced, it does NOT revert: it falls back to
    /// the public venue, returning its quote and `fallbackSwapRouter`, mirroring
    /// the execution-time safety net of `swapViaSelectedVenuesV1`. Only reverts
    /// `NoQuotesAvailable` if even the fallback cannot be priced.
    function quoteSelectedVenuesV1(address[] calldata venues, address tokenIn, address tokenOut, uint256 amountIn)
        public
        returns (uint256 bestAmountOut, address bestVenue)
    {
        if (tokenIn == ETH_SENTINEL) {
            tokenIn = WETH;
        }
        if (tokenOut == ETH_SENTINEL) {
            tokenOut = WETH;
        }

        (bestAmountOut, bestVenue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);
        if (bestVenue == address(0)) {
            // None of the considered venues could be priced; fall back to the
            // public venue, as documented by `IPropAMMRouter`.
            try this.quoteUniswapV3(tokenIn, tokenOut, amountIn) returns (uint256 fallbackOut) {
                bestAmountOut = fallbackOut;
                bestVenue = fallbackSwapRouter;
            } catch {
                revert NoQuotesAvailable();
            }
        }
    }

    /// @notice Strict single-venue quote: prices exactly `venue` and reverts if
    /// it cannot be priced.
    /// @dev Self-only. Declared `external` (despite the leading underscore) so
    /// the selection helpers and `quoteVenueV1` can reach it through `this.` and
    /// wrap it in a `try/catch` — internal calls cannot be caught. The two
    /// built-in propAMMs (Fermi, Bebop) are priced through their bespoke
    /// quoters; every other whitelisted venue through the common `IPropAMM.quote`. Reverts
    /// `UnknownVenue` for a non-whitelisted, non-fallback `venue`, and bubbles up
    /// any revert from the underlying quoter so callers can skip it. Unlike
    /// `quoteVenueV1`, it does NOT gracefully fall back to the public venue.
    /// @param venue The venue to price — a whitelisted propAMM or the fallback.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amount The amount of `tokenIn` to quote.
    /// @return amountOut The amount of `tokenOut` quoted by `venue`.
    function _dispatchQuoteVenue(address venue, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 amountOut)
    {
        require(msg.sender == address(this), OnlySelf());

        // The fallback (Uniswap V3) is the always-available safety net and is not
        // part of the propAMM whitelist, so it is checked before the gate.
        if (venue == fallbackSwapRouter) {
            return quoteUniswapV3(tokenIn, tokenOut, amount);
        }

        require(_whitelistedVenues.contains(venue), UnknownVenue());

        if (venue == FERMI_ROUTER) {
            int256 amountInt256 = amount.toInt256();
            (, amountOut) = IFermiSwapper(FERMI_ROUTER).quoteAmounts(tokenIn, tokenOut, amountInt256);
        } else if (venue == BEBOP_ROUTER) {
            amountOut = IBebopRouter(BEBOP_ROUTER).quote(tokenIn, tokenOut, amount);
        } else {
            // Any other whitelisted venue speaks the common `IPropAMM` interface.
            amountOut = IPropAMM(venue).quote(tokenIn, tokenOut, amount);
        }
    }

    /// @notice Quotes the Uniswap V3 fallback for the pair at its resolved fee
    /// tier (the per-pair override if set, otherwise the global `fallbackFee`).
    /// @dev Public so `_pickBestVenue` and `quoteSelectedVenuesV1` can wrap it
    /// in a `try/catch` through an external self-call (an internal library call
    /// can't be caught).
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` the Uniswap V3 swap would produce.
    function quoteUniswapV3(address tokenIn, address tokenOut, uint256 amount) public returns (uint256 amountOut) {
        return UniV3Router.quoteExactIn(tokenIn, tokenOut, resolvedFee(tokenIn, tokenOut), amount, fallbackQuoter);
    }

    /// @notice Finds the venue offering the best `tokenOut` for `amount` of
    /// `tokenIn` across the whitelisted propAMMs and the fallback.
    /// @dev Iterates the live venue whitelist (`_whitelistedVenues`), so venues
    /// added or removed via `addVenue` / `removeVenue` are reflected without a
    /// contract upgrade.
    /// Each venue is queried in its own `try/catch` so a reverting venue —
    /// including one listed ahead of its interface — is simply skipped. Returns
    /// `(0, fallbackSwapRouter)` when nothing can be priced — callers that need a
    /// hard failure (e.g. `quoteV1`) check the zero quote; `swapV1` instead lets
    /// `_coreSwap` route the `fallbackSwapRouter` to the fallback. The returned
    /// `venue` is either a whitelisted propAMM or `fallbackSwapRouter`.
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

        uint256 venueCount = whitelistedVenueCount();
        for (uint256 i = 0; i < venueCount; i++) {
            address candidate = whitelistedVenueAt(i);
            try this._dispatchQuoteVenue(candidate, tokenIn, tokenOut, amount) returns (uint256 amountOut) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    venue = candidate;
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
    /// @dev Quotes ONLY the provided `venues` (each via `this._dispatchQuoteVenue`
    /// in its own `try/catch`), so a venue that reverts — including a
    /// non-whitelisted address, which `_dispatchQuoteVenue` rejects with
    /// `UnknownVenue` — is simply skipped. It uses the strict quote (not
    /// `quoteVenueV1`) precisely so a failing venue is dropped rather than
    /// silently re-quoted as the public-venue fallback. Unlike `_pickBestVenue`, it does NOT seed or
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
            try this._dispatchQuoteVenue(venues[i], tokenIn, tokenOut, amount) returns (uint256 amountOut) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    venue = venues[i];
                }
            } catch {}
        }
    }

    //---------------------//
    // Fallback Management //
    //---------------------//

    /// @notice Repoints the address used by the fallback route.
    /// @dev Access-controlled via the AccessManager authority. Lets a new SwapRouter deployment be adopted without a
    /// contract upgrade. Reverts `ZeroAddress` if zero — this address also
    /// identifies the fallback venue (`_isVenue`, `_pickBestVenue`, `_coreSwap`),
    /// so a zero value would corrupt venue identity. Note that `executedVenue`
    /// values observed off-chain are only meaningful relative to the router's
    /// configuration at the time of the swap.
    /// @param newRouter Address of thew new router.
    function setFallbackSwapRouter(address newRouter) external restricted {
        require(newRouter != address(0), ZeroAddress());
        emit FallbackSwapRouterUpdated(fallbackSwapRouter, newRouter);
        fallbackSwapRouter = newRouter;
    }

    /// @notice Repoints the fallback quoter used to price the fallback route.
    /// @dev Access-controlled via the AccessManager authority. Reverts `ZeroAddress` if zero.
    /// @param newQuoter Address of the new fallback quoter.
    function setFallbackQuoter(address newQuoter) external restricted {
        require(newQuoter != address(0), ZeroAddress());
        emit FallbackQuoterUpdated(fallbackQuoter, newQuoter);
        fallbackQuoter = newQuoter;
    }

    /// @notice Sets the fallback fee used by the fallback route.
    /// @dev Access-controlled via the AccessManager authority. Lets the deepest pool for the traded pairs be selected
    /// without a contract upgrade.
    /// @param fee in hundredths of a bip (e.g. `3000` for 0.30%).
    function setFallbackFee(uint24 fee) external restricted {
        require(fee != 0 && fee < 1_000_000, InvalidFallbackFee(fee));
        emit FallbackFeeUpdated(fallbackFee, fee);
        fallbackFee = fee;
    }

    /// @dev Canonical key for a token pair, order-independent. Uniswap V3 pools
    /// are symmetric (one pool, `token0 < token1`, serves both directions), so
    /// {A,B} and {B,A} share one entry.
    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        (address a, address b) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(a, b));
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
    function resolvedFee(address tokenIn, address tokenOut) public view returns (uint24 fee) {
        fee = _pairFee[_pairKey(tokenIn, tokenOut)];
        if (fee == 0) fee = fallbackFee;
    }

    /// @notice Sets (or clears) the Uniswap V3 fallback fee tier for a specific pair.
    /// @dev Access-controlled via the AccessManager authority. Order-independent. Pass `fee == 0` to clear the override and
    /// revert the pair to the global `fallbackFee`. A tier with no pool simply makes
    /// the fallback quote revert and be skipped for that pair — it does not corrupt
    /// state.
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token of the pair.
    /// @param fee Fee tier in hundredths of a bip (e.g. `100` for 0.01%), or 0 to clear.
    function setPairFee(address tokenA, address tokenB, uint24 fee) external restricted {
        _setPairFee(tokenA, tokenB, fee);
    }

    /// @notice Sets (or clears) per-pair fallback fees for several pairs in one call.
    /// @dev Access-controlled via the AccessManager authority. The three arrays are zipped index-wise and must be equal
    /// length. Each entry follows the same rules as `setPairFee` (0 clears) and emits
    /// its own `PairFeeUpdated`.
    /// @param tokenA Array whose i-th element is one token of pair `i`.
    /// @param tokenB Array whose i-th element is the other token of pair `i`.
    /// @param fees Array whose i-th element is the tier for pair `i`, or 0 to clear.
    function setPairFees(address[] calldata tokenA, address[] calldata tokenB, uint24[] calldata fees)
        external
        restricted
    {
        require(tokenA.length == tokenB.length && tokenB.length == fees.length, ArrayLengthMismatch());
        for (uint256 i = 0; i < fees.length; i++) {
            _setPairFee(tokenA[i], tokenB[i], fees[i]);
        }
    }

    /// @dev Shared validate-emit-store for both setters. Mirrors `setFallbackFee`'s
    /// upper bound and reuses `InvalidFallbackFee`, but allows 0 (the "unset"
    /// sentinel that clears the override).
    function _setPairFee(address tokenA, address tokenB, uint24 fee) private {
        require(fee < 1_000_000, InvalidFallbackFee(fee)); // 0 allowed = clear
        bytes32 key = _pairKey(tokenA, tokenB);
        emit PairFeeUpdated(tokenA, tokenB, _pairFee[key], fee);
        _pairFee[key] = fee;
    }

    //----------------------//
    // Whitelist Management //
    //----------------------//

    /// @notice Adds a propAMM venue to the whitelist, allowing the router to route
    /// (and quote) through it — including as an auto-selection candidate in
    /// `swapV1` / `quoteV1`, which iterate the whitelist.
    /// @dev Access-controlled via the AccessManager authority. Reverts `ZeroAddress` if `venue` is zero, or
    /// `VenueAlreadyWhitelisted` if it is already listed. Other than the two
    /// built-in propAMMs (Fermi and Bebop, which use their bespoke interfaces),
    /// a venue is expected
    /// to implement the common `IPropAMM` interface. Listing an address that does
    /// not (an EOA, the wrong contract, a not-yet-deployed adapter) is not a
    /// foot-gun: its `quote`/`swap` calls revert, so it is skipped by selection
    /// and, on an explicit swap, the reverting `_dispatchVenue` rolls back and the
    /// Uniswap fallback engages — no funds are stranded.
    /// @param venue The venue address to whitelist.
    function addVenue(address venue) external restricted {
        _addVenue(venue);
    }

    /// @dev Shared whitelist-insertion core for the public `addVenue` and the
    /// venue seeding in `initialize`. Reverts `ZeroAddress` if `venue` is zero
    /// and `VenueAlreadyWhitelisted` if it is already listed; emits
    /// `VenueWhitelisted` on success.
    function _addVenue(address venue) private {
        require(venue != address(0), ZeroAddress());
        bool added = _whitelistedVenues.add(venue);

        if (added) {
            emit VenueWhitelisted(venue);
        } else {
            revert VenueAlreadyWhitelisted(venue);
        }
    }

    /// @notice Removes a propAMM venue from the whitelist, after which the router
    /// will neither quote nor route through it on any path.
    /// @dev Access-controlled via the AccessManager authority. Reverts `VenueNotWhitelisted` if `venue` is not listed.
    /// Does not affect the Uniswap fallback, which remains the always-available
    /// safety net.
    /// @param venue The venue address to de-list.
    function removeVenue(address venue) external restricted {
        require(_whitelistedVenues.remove(venue), VenueNotWhitelisted(venue));
        emit VenueRemoved(venue);
    }

    /// @notice Returns whether `venue` is a venue a caller may name explicitly in
    /// `quoteVenueV1` / `swapViaVenueV1`: a whitelisted propAMM, or the Uniswap
    /// fallback (which is always accepted, independent of the whitelist).
    function _isVenue(address venue) private view returns (bool) {
        return isWhitelistedVenue(venue) || venue == fallbackSwapRouter;
    }

    /// @notice Returns whether `venue` is a whitelisted propAMM.
    /// @dev Reflects only the propAMM whitelist. The Uniswap fallback
    /// (`fallbackSwapRouter`) is usable as a venue without being whitelisted, so
    /// this returns false for it — use it to inspect the propAMM set specifically.
    /// @param venue The address to check.
    function isWhitelistedVenue(address venue) public view returns (bool) {
        return _whitelistedVenues.contains(venue);
    }

    /// @notice Returns every whitelisted propAMM venue.
    /// @dev Excludes the Uniswap fallback (not a set member). Order is not
    /// guaranteed — `removeVenue` swap-and-pops, so positions shift. Intended for
    /// off-chain reads / `eth_call`; the set is access-controlled and small, but
    /// avoid calling this from another contract on a hot path.
    /// @return The list of whitelisted venue addresses.
    function getWhitelistedVenues() external view returns (address[] memory) {
        return _whitelistedVenues.values();
    }

    /// @notice Returns the number of whitelisted propAMM venues.
    /// @dev Pair with `whitelistedVenueAt` to enumerate on-chain without
    /// materializing the whole array.
    function whitelistedVenueCount() public view returns (uint256) {
        return _whitelistedVenues.length();
    }

    /// @notice Returns the whitelisted venue at `index`.
    /// @dev Reverts if `index >= whitelistedVenueCount()`. Order is not stable
    /// across `removeVenue` calls (swap-and-pop), so treat indices as ephemeral.
    /// @param index Position in `[0, whitelistedVenueCount())`.
    function whitelistedVenueAt(uint256 index) public view returns (address) {
        return _whitelistedVenues.at(index);
    }

    //---------------------//
    // Contract Management //
    //---------------------//

    /// @notice Rescues ERC-20 tokens or native ETH stranded on the router.
    /// @dev Access-controlled via the AccessManager authority. The router holds no balance between swaps, so any
    /// standing balance is unintended (mis-sent funds, fee-on-transfer dust, or
    /// a partial-pull remainder). Not `nonReentrant`: it must stay callable and
    /// it moves no in-flight swap funds — swaps are atomic and `nonReentrant`.
    /// @param token The ERC-20 to rescue, or `ETH_SENTINEL` to rescue native ETH.
    /// @param to The recipient of the rescued tokens.
    /// @param amount The amount to transfer.
    function rescueTokens(address token, address to, uint256 amount) external restricted {
        require(to != address(0), ZeroAddress());
        if (token == ETH_SENTINEL) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, ETHTransferFailed());
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit TokensRescued(token, to, amount);
    }

    /// @notice Pauses swaps, blocking new swaps until `unpause` is called.
    /// @dev Access-controlled via the AccessManager authority. Intended for an
    /// instant (zero-delay) guardian role: pausing is fail-safe — it can only
    /// restrict — so it must be able to fire immediately as a circuit breaker.
    /// Quote functions remain callable while paused.
    function pause() external restricted {
        _pause();
    }

    /// @notice Unpauses swaps.
    /// @dev Access-controlled via the AccessManager authority. Kept separate from
    /// the guardian's instant pause: resuming is fail-open, so it is intended for
    /// a deliberate role carrying its own (non-zero) execution delay.
    function unpause() external restricted {
        _unpause();
    }

    /// @dev Gates UUPS upgrades through the `AccessManager`. The `restricted`
    /// modifier keys off the *entering* selector, which for an upgrade is
    /// `upgradeToAndCall(address,bytes)`; assign the upgrade role and its
    /// execution delay to that selector on the manager. Using `restricted` on an
    /// internal function is the documented UUPS+AccessManaged pattern precisely
    /// because the gate resolves against that entrypoint selector.
    function _authorizeUpgrade(address) internal override restricted {}
}
