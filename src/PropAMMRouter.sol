// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "./interfaces/IPropAMMRouter.sol";
import {IPropAMM} from "./interfaces/IPropAMM.sol";
import {FERMI_ROUTER, IFermiSwapper} from "./interfaces/IFermiSwapper.sol";
import {BEBOP_ROUTER, IBebopRouter} from "./interfaces/IBebopRouter.sol";
import {KIPSELI_PAMM, IKipseliPAMM} from "./interfaces/IKipseliPAMM.sol";
import {KIPSELI_QUOTER, IKipseliQuoter} from "./interfaces/IKipseliQuoter.sol";
import {UniV3Router} from "./libraries/UniV3Router.sol";

/// @notice Fee parameters for the `*WithFeeV1` entrypoints. Bundled into a struct
/// so each entrypoint stays within the EVM stack limit without enabling `via_ir`.
/// @param bps Fee in basis points (1/10_000 of the output). Must be <= `MAX_FEE_BPS`.
/// @param recipient Address that receives the fee in `tokenOut`. Must be non-zero.
struct FrontendFee {
    uint16 bps;
    address recipient;
}

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
    using EnumerableSet for EnumerableSet.AddressSet;

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
    /// @notice Whitelist of propAMM venues the router may route through. This is
    /// the authoritative check for whether an address may be used as a propAMM
    /// (`_isVenue`, `quoteVenueV1`, `_dispatchVenue`): a venue de-listed here is
    /// skipped by every selection path and rejected on every explicit path. As an
    /// enumerable set it is also the source of candidates iterated by
    /// `_pickBestVenue`, so a venue added via `addVenue` is automatically
    /// considered by `swapV1` / `quoteV1` without a contract upgrade. The Uniswap
    /// V3 fallback (`fallbackSwapRouter`) is the always-available safety net and is
    /// intentionally NOT a member — it is accepted independently of this set.
    /// Seeded with the known propAMMs in `initialize` and owner-managed via
    /// `addVenue` / `removeVenue`. Owner-controlled, so its size (and thus the
    /// `_pickBestVenue` loop bound) is trusted to stay small.
    /// @dev Declared last to keep the upgradeable storage layout append-only.
    EnumerableSet.AddressSet private _whitelistedVenues;

    // Mainnet token addresses for the default per-pair fallback tiers seeded by
    // `initialize` (see `_seedDefaultPairFees`). Mainnet-specific by design: on
    // other chains these point at the wrong tokens, which is harmless — they are
    // only consulted for these exact addresses, and the owner can clear/override
    // any entry via `setPairFee`.
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Hard cap on a frontend fee, in basis points (1.00%).
    uint16 public constant MAX_FEE_BPS = 100;
    /// @notice Basis-point denominator (100% = 10_000 bps).
    uint16 public constant BPS_DENOMINATOR = 10_000;

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
    /// @notice Thrown when a requested frontend fee exceeds `MAX_FEE_BPS`.
    /// @param requested The caller-supplied fee in basis points.
    /// @param max The maximum allowed fee (`MAX_FEE_BPS`).
    error FeeBpsTooHigh(uint16 requested, uint16 max);
    /// @notice Thrown when `setPairFees` is given arrays of unequal length.
    error ArrayLengthMismatch();
    /// @notice Thrown when `addVenue` is given a venue already on the whitelist.
    error VenueAlreadyWhitelisted(address venue);
    /// @notice Thrown when `removeVenue` is given a venue not on the whitelist.
    error VenueNotWhitelisted(address venue);

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
    /// @notice Emitted when the owner sets or clears a per-pair fallback fee.
    /// @param tokenA One token of the pair (as supplied to the setter).
    /// @param tokenB The other token of the pair (as supplied to the setter).
    /// @param oldFee The previous override (0 if it was unset).
    /// @param newFee The new override (0 means cleared / use global default).
    event PairFeeUpdated(address indexed tokenA, address indexed tokenB, uint24 oldFee, uint24 newFee);
    /// @notice Emitted when the owner rescues tokens stranded on the router.
    /// @param token The ERC-20 rescued.
    /// @param to The recipient of the rescued tokens.
    /// @param amount The amount transferred.
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted when a propAMM venue is added to the whitelist — via
    /// `addVenue`, or for each seeded default venue during `initialize` /
    /// `initializeVenueWhitelist`.
    /// @param venue The venue address added.
    event VenueWhitelisted(address indexed venue);
    /// @notice Emitted when the owner removes a propAMM venue from the whitelist.
    /// @param venue The venue address removed.
    event VenueRemoved(address indexed venue);
    /// @notice Emitted when a frontend fee is skimmed from a `*WithFeeV1` swap output.
    /// @param feeRecipient The address that received the fee.
    /// @param tokenOut The output token the fee was taken in.
    /// @param feeAmount The fee amount transferred to `feeRecipient`.
    /// @param payer The account that invoked the swap and bore the fee.
    event FrontendFeeCharged(
        address indexed feeRecipient,
        address indexed tokenOut,
        uint256 feeAmount,
        address indexed payer
    );

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
    /// @dev Also seeds the deep mainnet Uniswap V3 fallback tiers via
    /// `_seedDefaultPairFees` and the known propAMMs onto the venue whitelist via
    /// `_seedDefaultVenues`, so a from-scratch deploy is pre-configured without a
    /// separate owner-run seeding step. Runs only here (initializer-gated), so it
    /// never re-applies on a UUPS upgrade of an existing proxy — proxies deployed
    /// before the whitelist existed backfill it via `initializeVenueWhitelist`.
    function initialize(address fallbackSwapRouter_, address fallbackQuoter_, address owner_) public initializer {
        require(fallbackSwapRouter_ != address(0), ZeroAddress());
        require(fallbackQuoter_ != address(0), ZeroAddress());
        fallbackSwapRouter = fallbackSwapRouter_;
        fallbackQuoter = fallbackQuoter_;
        fallbackFee = 3000;
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        _seedDefaultPairFees();
        _seedDefaultVenues();
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

    /// @notice Seeds the whitelist with the propAMMs the router ships with so a
    /// from-scratch deploy can route to them without a separate owner-run step.
    /// @dev Routes through `_addVenue` (the same core the public `addVenue` uses),
    /// so it is safe to run against an already-seeded proxy: an entry that is
    /// already listed is left untouched and emits nothing, while a newly added
    /// entry emits `VenueWhitelisted`.
    function _seedDefaultVenues() private {
        _addVenue(FERMI_ROUTER);
        _addVenue(KIPSELI_PAMM);
        _addVenue(BEBOP_ROUTER);
    }

    /// @dev Shared whitelist-insertion core for the public `addVenue` and the
    /// seeding paths (`_seedDefaultVenues`). Adds `venue` if absent and emits
    /// `VenueWhitelisted` only when the set actually changed; idempotent, so the
    /// seeding paths never revert on a venue that is already listed. Callers that
    /// must reject a redundant add (the public `addVenue`) check the return value.
    /// @return added True if `venue` was newly inserted, false if already present.
    function _addVenue(address venue) private returns (bool added) {
        added = _whitelistedVenues.add(venue);
        if (added) emit VenueWhitelisted(venue);
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
        (amountOut, executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Best-venue swap that skims a frontend fee from the output token.
    /// @dev Implementation-only (not in `IPropAMMRouter`). Validates `fee`, grosses up
    /// the net `amountOutMin` so the user still nets at least their minimum, routes the
    /// swap to this contract, then forwards the fee and the net. Emits `Swapped` with the
    /// net amount and the real `recipient`. `whenNotPaused`/`nonReentrant` like `swapV1`.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum NET `tokenOut` the user must receive (after the fee).
    /// @param recipient The address that receives the net `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @param fee The frontend fee (bps + recipient).
    /// @return amountOut The net `tokenOut` delivered to `recipient`.
    /// @return executedVenue The venue that filled, or the fallback venue address.
    function swapWithFeeV1(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        _validateFee(fee);
        require(block.timestamp <= deadline, Expired());

        uint256 grossMin = _grossUp(amountOutMin, fee.bps);
        address venue;
        {
            uint256 bestQuote;
            (bestQuote, venue) = _pickBestVenue(tokenIn, tokenOut, amountIn);
            require(bestQuote >= grossMin, QuoteBelowMinimum(grossMin, bestQuote));
        }

        uint256 delivered;
        (delivered, executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = _skimAndDisburse(tokenOut, delivered, fee, recipient);
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
    ) public whenNotPaused nonReentrant returns (uint256 amountOut) {
        require(_isVenue(venue), UnknownVenue());
        address executedVenue;
        (amountOut, executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Caller-named-venue swap that skims a frontend fee from the output token.
    /// @dev Implementation-only. Like `swapViaVenueV1` plus the fee skim; the underlying
    /// swap is routed to this contract, then fee + net are forwarded. Reverts `UnknownVenue`
    /// if `venue` is neither a whitelisted propAMM nor the fallback address.
    /// @param venue The venue address (propAMM or the fallback router address).
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum NET `tokenOut` the user must receive (after the fee).
    /// @param recipient The address that receives the net `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @param fee The frontend fee (bps + recipient).
    /// @return amountOut The net `tokenOut` delivered to `recipient`.
    function swapViaVenueWithFeeV1(
        address venue,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external whenNotPaused nonReentrant returns (uint256 amountOut) {
        _validateFee(fee);
        require(_isVenue(venue), UnknownVenue());

        uint256 grossMin = _grossUp(amountOutMin, fee.bps);
        (uint256 delivered, address executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = _skimAndDisburse(tokenOut, delivered, fee, recipient);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Requotes ONLY the caller-supplied `venues` on-chain via
    /// `_pickBestVenueFrom`, and if any venue returns a quote that is at least
    /// `amountOutMin`, then attempts to swap via that venue. Otherwise, it defaults
    /// to swapping via Uniswap V3
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
        // If no quotes are available, or the best quote is below the minimum,
        // default to the Uniswap fallback venue instead of reverting (#9).
        if (venue == address(0) || bestQuote < amountOutMin) {
            venue = fallbackSwapRouter;
        }
        (amountOut, executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Best-of-a-subset swap that skims a frontend fee from the output token.
    /// @dev Implementation-only. Like `swapViaSelectedVenuesV1` plus the fee skim; requotes
    /// only `venues`, grosses up the net min, routes the swap to this contract, then forwards
    /// fee + net. Reverts `NoQuotesAvailable` if none of `venues` can be priced.
    /// @param venues The venues to consider — a subset of the available venues.
    /// @param tokenIn The token being sold.
    /// @param tokenOut The token being bought.
    /// @param amountIn The exact amount of `tokenIn` to sell.
    /// @param amountOutMin The minimum NET `tokenOut` the user must receive (after the fee).
    /// @param recipient The address that receives the net `tokenOut`.
    /// @param deadline Unix timestamp after which the swap is no longer valid.
    /// @param fee The frontend fee (bps + recipient).
    /// @return amountOut The net `tokenOut` delivered to `recipient`.
    /// @return executedVenue The venue that filled, or the fallback venue address.
    function swapViaSelectedVenuesWithFeeV1(
        address[] calldata venues,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external whenNotPaused nonReentrant returns (uint256 amountOut, address executedVenue) {
        _validateFee(fee);
        require(block.timestamp <= deadline, Expired());

        uint256 grossMin = _grossUp(amountOutMin, fee.bps);
        address venue;
        {
            uint256 bestQuote;
            (bestQuote, venue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);
            require(venue != address(0), NoQuotesAvailable());
            require(bestQuote >= grossMin, QuoteBelowMinimum(grossMin, bestQuote));
        }

        uint256 delivered;
        (delivered, executedVenue) =
            _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = _skimAndDisburse(tokenOut, delivered, fee, recipient);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    /// @notice Pulls funds once and executes a swap, attempting `venue` first
    /// and recovering via the fallback if it fails.
    /// @dev Shared core for `swapV1` and `swapViaVenueV1`; unguarded so the two
    /// public entrypoints can each apply `whenNotPaused`/`nonReentrant` without
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
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 prevTokenOutBalance = IERC20(tokenOut).balanceOf(recipient);

        if (venue != fallbackSwapRouter) {
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
        return (amountOut, fallbackSwapRouter);
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

    /// @notice Reverts unless the frontend fee is within cap and has a real recipient.
    /// @param fee The caller-supplied fee parameters.
    function _validateFee(FrontendFee calldata fee) private pure {
        require(fee.bps <= MAX_FEE_BPS, FeeBpsTooHigh(fee.bps, MAX_FEE_BPS));
        require(fee.recipient != address(0), ZeroAddress());
    }

    /// @notice Grosses up a net `amountOutMin` so the post-fee output still meets it.
    /// @dev `ceilDiv` rounds up to avoid a 1-wei false revert at the slippage boundary.
    /// Safe from divide-by-zero because `feeBps <= MAX_FEE_BPS < BPS_DENOMINATOR`.
    /// @param amountOutMin The net minimum the user must receive.
    /// @param feeBps The fee in basis points.
    /// @return grossMin The gross minimum the underlying swap must deliver.
    function _grossUp(uint256 amountOutMin, uint16 feeBps) private pure returns (uint256 grossMin) {
        grossMin = Math.ceilDiv(amountOutMin * BPS_DENOMINATOR, BPS_DENOMINATOR - feeBps);
    }

    /// @notice Floored basis-point fee on `amount`.
    /// @param amount The gross amount the fee is taken from.
    /// @param feeBps The fee in basis points.
    /// @return The fee amount (rounds down, favoring the user).
    function _feeAmount(uint256 amount, uint16 feeBps) private pure returns (uint256) {
        return amount * feeBps / BPS_DENOMINATOR;
    }

    /// @notice Splits `delivered` tokenOut (held by this contract) into fee + net,
    /// forwards the fee to `fee.recipient` and the net to `recipient`.
    /// @dev Zero-value legs are skipped (gas + tokens that revert on 0-value transfers).
    /// @param tokenOut The output token held by this contract.
    /// @param delivered The gross amount this contract received from the swap.
    /// @param fee The fee parameters.
    /// @param recipient The end recipient of the net output.
    /// @return net The amount forwarded to `recipient`.
    function _skimAndDisburse(
        address tokenOut,
        uint256 delivered,
        FrontendFee calldata fee,
        address recipient
    ) private returns (uint256 net) {
        uint256 feeAmt = _feeAmount(delivered, fee.bps);
        net = delivered - feeAmt;
        if (feeAmt > 0) {
            IERC20(tokenOut).safeTransfer(fee.recipient, feeAmt);
            emit FrontendFeeCharged(fee.recipient, tokenOut, feeAmt, msg.sender);
        }
        if (net > 0) {
            IERC20(tokenOut).safeTransfer(recipient, net);
        }
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
        require(_whitelistedVenues.contains(venue), UnknownVenue());

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
            // Any other whitelisted venue speaks the common `IPropAMM` interface.
            // Push-payment model: transfer `tokenIn` first, then let the venue
            // consume it and deliver `tokenOut` straight to `recipient`. A revert
            // (or an under-delivery caught below) rolls back this transfer via the
            // `_coreSwap` self-call `try/catch` and engages the Uniswap fallback.
            IERC20(tokenIn).safeTransfer(venue, amountIn);
            IPropAMM(venue).swap(tokenIn, tokenOut, amountIn, amountOutMin, recipient);
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
    /// once by `_coreSwap` before the try/catch. Uses the per-pair resolved fee
    /// tier (`_resolveFee`: the pair override if set, otherwise the global
    /// `fallbackFee`). `UniV3Router.swapExactIn` only approves `fallbackSwapRouter`
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
            tokenIn, tokenOut, _resolveFee(tokenIn, tokenOut), amountIn, amountOutMin, recipient, fallbackSwapRouter
        );
        return amountOut;
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenue` (which compares the proprietary AMMs
    /// and fallback) and reverts `NoQuotesAvailable` if nothing could be priced.
    function quoteV1(address tokenIn, address tokenOut, uint256 amount)
        public
        view
        returns (uint256 bestQuote, address venue)
    {
        (bestQuote, venue) = _pickBestVenue(tokenIn, tokenOut, amount);
        require(bestQuote > 0, NoQuotesAvailable());
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev The Uniswap fallback is always quotable; any other `venue` must be on
    /// the whitelist (`_whitelistedVenues`), otherwise reverts `UnknownVenue`.
    /// The three built-in propAMMs are priced through their bespoke quoters; every
    /// other whitelisted venue is priced through the common `IPropAMM.quote`
    /// interface. Because the selection helpers (`_pickBestVenue`,
    /// `_pickBestVenueFrom`) call this in a `try/catch`, a de-listed venue (or one
    /// whose quote reverts, e.g. an address that does not implement `IPropAMM`) is
    /// simply skipped rather than surfaced.
    function quoteVenueV1(address venue, address tokenIn, address tokenOut, uint256 amount)
        public
        view
        returns (uint256 amountOut)
    {
        // The fallback (Uniswap V3) is the always-available safety net and is not
        // part of the propAMM whitelist, so it is checked before the gate.
        if (venue == fallbackSwapRouter) {
            return UniV3Router.quoteExactIn(tokenIn, tokenOut, _resolveFee(tokenIn, tokenOut), amount, fallbackQuoter);
        }

        require(_whitelistedVenues.contains(venue), UnknownVenue());

        if (venue == FERMI_ROUTER) {
            int256 amountInt256 = amount.toInt256();
            (, amountOut) = IFermiSwapper(FERMI_ROUTER).quoteAmounts(tokenIn, tokenOut, amountInt256);
        } else if (venue == KIPSELI_PAMM) {
            amountOut = IKipseliQuoter(KIPSELI_QUOTER)
                .preSwapQuote(tokenIn, amount, tokenOut, block.timestamp * 1000, address(0));
        } else if (venue == BEBOP_ROUTER) {
            amountOut = IBebopRouter(BEBOP_ROUTER).quote(tokenIn, tokenOut, amount);
        } else {
            // Any other whitelisted venue speaks the common `IPropAMM` interface.
            amountOut = IPropAMM(venue).quote(tokenIn, tokenOut, amount);
        }
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenueFrom`, considering ONLY `venues`, and
    /// reverts `NoQuotesAvailable` if none of them can be priced. Venues that
    /// revert while quoting — including non-whitelisted addresses, which
    /// `quoteVenueV1` rejects with `UnknownVenue` — are skipped, not surfaced.
    function quoteSelectedVenuesV1(address[] calldata venues, address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        returns (uint256 bestAmountOut, address bestVenue)
    {
        (bestAmountOut, bestVenue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);
        require(bestAmountOut > 0, NoQuotesAvailable());
    }

    /// @notice Quotes the Uniswap V3 fallback for the pair at its resolved fee
    /// tier (the per-pair override if set, otherwise the global `fallbackFee`).
    /// @dev External so `_pickBestVenue` and `quoteV1` can wrap it in a
    /// `try/catch` (an internal library call can't be caught).
    /// @param tokenIn The address of the token being sold.
    /// @param tokenOut The address of the token being bought.
    /// @param amount The exact amount of `tokenIn` to quote against.
    /// @return amountOut The amount of `tokenOut` the Uniswap V3 swap would produce.
    function quoteUniswapV3(address tokenIn, address tokenOut, uint256 amount) external view returns (uint256 amountOut) {
        return UniV3Router.quoteExactIn(tokenIn, tokenOut, _resolveFee(tokenIn, tokenOut), amount, fallbackQuoter);
    }

    /// @notice Finds the venue offering the best `tokenOut` for `amount` of
    /// `tokenIn` across the whitelisted propAMMs and the fallback.
    /// @dev Iterates the live venue whitelist (`_whitelistedVenues`), so venues
    /// added or removed by the owner are reflected without a contract upgrade.
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

        uint256 venueCount = _whitelistedVenues.length();
        for (uint256 i = 0; i < venueCount; i++) {
            address candidate = _whitelistedVenues.at(i);
            try this.quoteVenueV1(candidate, tokenIn, tokenOut, amount) returns (uint256 amountOut) {
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
    /// `quoteVenueV1` / `swapViaVenueV1`: a whitelisted propAMM, or the Uniswap
    /// fallback (which is always accepted, independent of the whitelist).
    function _isVenue(address venue) private view returns (bool) {
        if (venue == address(0)) return false;
        return _whitelistedVenues.contains(venue) || venue == fallbackSwapRouter;
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

    /// @notice Sets (or clears) the Uniswap V3 fallback fee tier for a specific pair.
    /// @dev Owner-gated. Order-independent. Pass `fee == 0` to clear the override and
    /// revert the pair to the global `fallbackFee`. A tier with no pool simply makes
    /// the fallback quote revert and be skipped for that pair — it does not corrupt
    /// state.
    /// @param tokenA One token of the pair.
    /// @param tokenB The other token of the pair.
    /// @param fee Fee tier in hundredths of a bip (e.g. `100` for 0.01%), or 0 to clear.
    function setPairFee(address tokenA, address tokenB, uint24 fee) external onlyOwner {
        _setPairFee(tokenA, tokenB, fee);
    }

    /// @notice Sets (or clears) per-pair fallback fees for several pairs in one call.
    /// @dev Owner-gated. The three arrays are zipped index-wise and must be equal
    /// length. Each entry follows the same rules as `setPairFee` (0 clears) and emits
    /// its own `PairFeeUpdated`.
    /// @param tokenA Array whose i-th element is one token of pair `i`.
    /// @param tokenB Array whose i-th element is the other token of pair `i`.
    /// @param fees Array whose i-th element is the tier for pair `i`, or 0 to clear.
    function setPairFees(address[] calldata tokenA, address[] calldata tokenB, uint24[] calldata fees)
        external
        onlyOwner
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

    /// @notice Returns whether `venue` is a whitelisted propAMM.
    /// @dev Reflects only the propAMM whitelist. The Uniswap fallback
    /// (`fallbackSwapRouter`) is usable as a venue without being whitelisted, so
    /// this returns false for it — use it to inspect the propAMM set specifically.
    /// @param venue The address to check.
    function isWhitelistedVenue(address venue) external view returns (bool) {
        return _whitelistedVenues.contains(venue);
    }

    /// @notice Returns every whitelisted propAMM venue.
    /// @dev Excludes the Uniswap fallback (not a set member). Order is not
    /// guaranteed — `removeVenue` swap-and-pops, so positions shift. Intended for
    /// off-chain reads / `eth_call`; the set is owner-controlled and small, but
    /// avoid calling this from another contract on a hot path.
    /// @return The list of whitelisted venue addresses.
    function getWhitelistedVenues() external view returns (address[] memory) {
        return _whitelistedVenues.values();
    }

    /// @notice Returns the number of whitelisted propAMM venues.
    /// @dev Pair with `whitelistedVenueAt` to enumerate on-chain without
    /// materializing the whole array.
    function whitelistedVenueCount() external view returns (uint256) {
        return _whitelistedVenues.length();
    }

    /// @notice Returns the whitelisted venue at `index`.
    /// @dev Reverts if `index >= whitelistedVenueCount()`. Order is not stable
    /// across `removeVenue` calls (swap-and-pop), so treat indices as ephemeral.
    /// @param index Position in `[0, whitelistedVenueCount())`.
    function whitelistedVenueAt(uint256 index) external view returns (address) {
        return _whitelistedVenues.at(index);
    }

    /// @notice Adds a propAMM venue to the whitelist, allowing the router to route
    /// (and quote) through it — including as an auto-selection candidate in
    /// `swapV1` / `quoteV1`, which iterate the whitelist.
    /// @dev Owner-gated. Reverts `ZeroAddress` if `venue` is zero, or
    /// `VenueAlreadyWhitelisted` if it is already listed. Other than the three
    /// built-in propAMMs (which use their bespoke interfaces), a venue is expected
    /// to implement the common `IPropAMM` interface. Listing an address that does
    /// not (an EOA, the wrong contract, a not-yet-deployed adapter) is not a
    /// foot-gun: its `quote`/`swap` calls revert, so it is skipped by selection
    /// and, on an explicit swap, the reverting `_dispatchVenue` rolls back and the
    /// Uniswap fallback engages — no funds are stranded.
    /// @param venue The venue address to whitelist.
    function addVenue(address venue) external onlyOwner {
        require(venue != address(0), ZeroAddress());
        require(_addVenue(venue), VenueAlreadyWhitelisted(venue));
    }

    /// @notice Removes a propAMM venue from the whitelist, after which the router
    /// will neither quote nor route through it on any path.
    /// @dev Owner-gated. Reverts `VenueNotWhitelisted` if `venue` is not listed.
    /// Does not affect the Uniswap fallback, which remains the always-available
    /// safety net.
    /// @param venue The venue address to de-list.
    function removeVenue(address venue) external onlyOwner {
        require(_whitelistedVenues.remove(venue), VenueNotWhitelisted(venue));
        emit VenueRemoved(venue);
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
