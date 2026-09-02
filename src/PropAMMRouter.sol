// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPropAMMRouter} from "./interfaces/IPropAMMRouter.sol";
import {IPropAMM} from "./interfaces/IPropAMM.sol";
import {IPropAMMPartialFill} from "./interfaces/IPropAMMPartialFill.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {BEBOP_ROUTER, IBebopRouter} from "./interfaces/IBebopRouter.sol";
import {UniV3Router} from "./libraries/UniV3Router.sol";
import {SplitPlanner} from "./libraries/SplitPlanner.sol";
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
    /// Starts empty (`initialize` seeds no venues) and is managed (access-controlled)
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
    /// Reverts `InsufficientOutput`
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
        require(bestQuote >= amountOutMin, InsufficientOutput(amountOutMin, bestQuote));

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
        (uint256 bestQuote, address venue) = _pickBestVenue(tokenIn, tokenOut, amountIn);

        require(bestQuote >= grossMin, InsufficientOutput(grossMin, bestQuote));

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
        (uint256 bestQuote, address venue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);

        if (venue == address(0) || bestQuote < amountOutMin) {
            venue = fallbackSwapRouter;
        }

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
        (uint256 bestQuote, address venue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);

        if (venue == address(0) || bestQuote < amountOutMin) {
            venue = fallbackSwapRouter;
        }

        uint256 delivered;
        (delivered, executedVenue) = _coreSwap(venue, tokenIn, tokenOut, amountIn, grossMin, address(this), deadline);

        amountOut = FrontendFees._skimAndDisburse(tokenOut, delivered, fee, recipient);
        _emitSwapped(executedVenue, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    //------------//
    // Multileg   //
    //------------//

    /// @notice Maximum number of legs per multileg call and venues per split.
    uint256 public constant MAX_SPLIT_VENUES = 8;

    /// @dev Bundled `_executeLegs` inputs. A struct rather than nine
    /// positional parameters for two reasons: it keeps the function under the
    /// stack limit, and it names the two distinct recipients so a call site
    /// cannot transpose them. `payTo` is where legs deliver — the router
    /// itself for the fee variants, which must hold the gross output to skim
    /// from it. `swapFor` is the user the swap is actually for and is used
    /// ONLY for `Swapped` events: an indexer attributing volume by the event's
    /// recipient must see the user, not the router.
    struct LegRun {
        address tokenIn; // caller-visible, may be the ETH sentinel
        address tokenIn_; // the resolved ERC-20 the legs sell
        address tokenOut; // caller-visible, may be the ETH sentinel
        uint256 amountOutMin; // aggregate floor on the total delivered
        uint256 fallbackMinOut; // caller's floor on the coalesced Uniswap swap
        address payTo; // where legs deliver
        address swapFor; // whom the swap is for (events only)
        uint256 deadline;
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev The coalesced fallback swap's floor is the largest of the
    /// aggregate shortfall against `amountOutMin`, the sum of the EXPLICIT
    /// fallback legs' `minOut`, and `fallbackMinOut` — see `_executeLegs`. A
    /// failed prop leg's own `minOut` is deliberately not carried in: it was
    /// priced off that venue's (typically better) rate, so applying it to
    /// Uniswap would revert the fallback exactly when it is needed to recover
    /// the leg.
    ///
    /// The shortfall term is best-effort ONLY. It collapses to zero the
    /// moment the prop legs that succeeded clear `amountOutMin`, which is the
    /// normal outcome of splitting into better-than-Uniswap venues, so a
    /// caller relying on it alone leaves the fallback slice MEV-exposed.
    /// `fallbackMinOut` is the term that actually protects that slice, and it
    /// is caller-supplied for an unavoidable reason: the fair Uniswap rate is
    /// information the router can only obtain from an onchain quote against
    /// the same pool in the same transaction, which a sandwich attacker moves
    /// along with the floor. No formula over the router's own state can
    /// substitute, and two tempting formulas are both unsound for the same
    /// reason — they apply a rate measured at one size to a different size.
    /// A pro-rata share of `amountOutMin` demands the Uniswap slice deliver
    /// at the BLENDED rate of the better-priced prop legs; scaling the
    /// explicit fallback legs' `minOut` up over the merged slice demands the
    /// small-size Uniswap rate at large size. Both revert sound swaps.
    function swapMultiLegV1(
        IPropAMMRouter.Leg[] calldata legs,
        address tokenIn,
        address tokenOut,
        uint256 amountOutMin,
        uint256 fallbackMinOut,
        address recipient,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        require(block.timestamp <= deadline, Expired());
        uint256 totalIn = _validateLegs(legs);
        address tokenIn_ = _pullFunds(tokenIn, totalIn);
        amountOut = _executeLegs(
            legs,
            LegRun({
                tokenIn: tokenIn,
                tokenIn_: tokenIn_,
                tokenOut: tokenOut,
                amountOutMin: amountOutMin,
                fallbackMinOut: fallbackMinOut,
                payTo: recipient,
                swapFor: recipient,
                deadline: deadline
            })
        );
    }

    /// @notice `swapMultiLegV1` plus a frontend fee skimmed from the
    /// aggregate output. Implementation-only, like the other `*WithFeeV1`
    /// entrypoints. Legs deliver to this contract; the fee and the net are
    /// then forwarded.
    /// @dev BOTH `amountOutMin` and `fallbackMinOut` are NET minimums — what
    /// the user must be left with after the fee. Each is grossed up by
    /// `fee.bps` before it reaches `_executeLegs`, which applies its floors
    /// to the pre-fee amounts the legs actually deliver. Grossing up both
    /// keeps one basis across the whole signature; forwarding
    /// `fallbackMinOut` raw would silently give the caller up to `fee.bps`
    /// less protection on that slice than the same number buys them via
    /// `amountOutMin`.
    function swapMultiLegWithFeeV1(
        IPropAMMRouter.Leg[] calldata legs,
        address tokenIn,
        address tokenOut,
        uint256 amountOutMin,
        uint256 fallbackMinOut,
        address recipient,
        uint256 deadline,
        FrontendFee calldata fee
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        FrontendFees._validateFee(fee);
        require(block.timestamp <= deadline, Expired());
        uint256 totalIn = _validateLegs(legs);
        uint256 grossMin = FrontendFees._grossUp(amountOutMin, fee.bps);
        uint256 grossFallbackMin = FrontendFees._grossUp(fallbackMinOut, fee.bps);
        address tokenIn_ = _pullFunds(tokenIn, totalIn);
        uint256 deliveredGross = _executeLegs(
            legs,
            LegRun({
                tokenIn: tokenIn,
                tokenIn_: tokenIn_,
                tokenOut: tokenOut,
                amountOutMin: grossMin,
                fallbackMinOut: grossFallbackMin,
                payTo: address(this),
                swapFor: recipient,
                deadline: deadline
            })
        );
        amountOut = FrontendFees._skimAndDisburse(tokenOut, deliveredGross, fee, recipient);
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Bounds `amountIn` to uint128 so every cross-multiplied rate
    /// comparison in `SplitPlanner` stays below 2^256, then plans and executes
    /// in one transaction. The planned legs always sum to `amountIn`, so the
    /// caller's `amountOutMin` is enforced by `_executeLegs` against the
    /// aggregate delivery exactly as in `swapMultiLegV1`.
    ///
    /// The same MEV caveat applies to the slice of the coalesced fallback
    /// covering legs that failed at execution time, but `swapMultiLegV1`'s
    /// remedy does NOT: a caller here cannot supply explicit fallback legs,
    /// because the router plans the legs. `fallbackMinOut` is that remedy's
    /// replacement — an absolute floor on the coalesced swap. It has to come
    /// from the caller: a floor the router derived from its own reference
    /// quote would be read from the same Uniswap pool in the same
    /// transaction, so a sandwich attacker moving that pool would move the
    /// floor along with it and the "protection" would be vacuous.
    function swapSplitV1(
        address[] calldata venues,
        uint256[] calldata probeHints,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 fallbackMinOut,
        uint256 maxLegs,
        address recipient,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        require(block.timestamp <= deadline, Expired());
        require(amountIn > 0, ZeroAmount());
        require(amountIn <= type(uint128).max, AmountTooLarge(amountIn));
        require(maxLegs >= 1, InvalidMaxLegs(maxLegs));

        (address[] memory venueSet, uint256[] memory hints) = _resolveVenueSet(venues, probeHints);

        address tokenIn_ = _pullFunds(tokenIn, amountIn);
        address tokenOut_ = tokenOut == ETH_SENTINEL ? WETH : tokenOut;

        IPropAMMRouter.Leg[] memory legs = _planSplit(venueSet, hints, tokenIn_, tokenOut_, amountIn, maxLegs);
        // `_validateLegs` is deliberately NOT called here, and restoring it
        // would break every split that uses all 8 prop legs: a plan may
        // legitimately hold MAX_SPLIT_VENUES prop legs PLUS the coalesced
        // remainder leg, and 9 legs trips its `InvalidLegCount` bound. Each
        // invariant it would have checked is already established by
        // construction: venue membership by `_probeVenue`'s `_isVenue` gate
        // (re-checked at execution by `_dispatchVenue`, so a mid-transaction
        // de-listing degrades to the fallback rather than stranding funds);
        // non-zero leg amounts by `_gatherCandidates` dropping `fill == 0`
        // candidates and `_waterfall` appending the remainder leg only while
        // `remaining > 0`; and `msg.value` by `_pullFunds` above.
        amountOut = _executeLegs(
            legs,
            LegRun({
                tokenIn: tokenIn,
                tokenIn_: tokenIn_,
                tokenOut: tokenOut,
                amountOutMin: amountOutMin,
                fallbackMinOut: fallbackMinOut,
                payTo: recipient,
                swapFor: recipient,
                deadline: deadline
            })
        );
    }

    /// @notice `swapSplitV1` plus a frontend fee skimmed from the aggregate
    /// output. Implementation-only.
    /// @dev BOTH `amountOutMin` and `fallbackMinOut` are NET minimums — what
    /// the user must be left with after the fee — and each is grossed up by
    /// `fee.bps` before reaching `_executeLegs`, which applies its floors to
    /// the pre-fee amounts the legs deliver. Grossing up both keeps one basis
    /// across the whole signature; forwarding `fallbackMinOut` raw would
    /// silently give the caller up to `fee.bps` less protection on that slice
    /// than the same number buys them via `amountOutMin`.
    function swapSplitWithFeeV1(
        address[] calldata venues,
        uint256[] calldata probeHints,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 fallbackMinOut,
        uint256 maxLegs,
        address recipient,
        uint256 deadline,
        IPropAMMRouter.FrontendFee calldata fee
    ) external payable whenNotPaused nonReentrant returns (uint256 amountOut) {
        FrontendFees._validateFee(fee);
        require(block.timestamp <= deadline, Expired());
        require(amountIn > 0, ZeroAmount());
        require(amountIn <= type(uint128).max, AmountTooLarge(amountIn));
        require(maxLegs >= 1, InvalidMaxLegs(maxLegs));

        (address[] memory venueSet, uint256[] memory hints) = _resolveVenueSet(venues, probeHints);
        uint256 grossMin = FrontendFees._grossUp(amountOutMin, fee.bps);
        uint256 grossFallbackMin = FrontendFees._grossUp(fallbackMinOut, fee.bps);

        address tokenIn_ = _pullFunds(tokenIn, amountIn);
        address tokenOut_ = tokenOut == ETH_SENTINEL ? WETH : tokenOut;
        IPropAMMRouter.Leg[] memory legs = _planSplit(venueSet, hints, tokenIn_, tokenOut_, amountIn, maxLegs);

        uint256 deliveredGross = _executeLegs(
            legs,
            LegRun({
                tokenIn: tokenIn,
                tokenIn_: tokenIn_,
                tokenOut: tokenOut,
                amountOutMin: grossMin,
                fallbackMinOut: grossFallbackMin,
                payTo: address(this),
                swapFor: recipient,
                deadline: deadline
            })
        );
        amountOut = FrontendFees._skimAndDisburse(tokenOut, deliveredGross, fee, recipient);
    }

    /// @dev Resolves the candidate venue set: the caller's list, or the whole
    /// whitelist when empty. Validates set size and the probeHints shape
    /// (length 0 or venues.length; must be 0 in whitelist mode).
    /// @param venues The caller-supplied venue list, or empty for the whitelist.
    /// @param probeHints The caller-supplied probe sizes, or empty for none.
    /// @return venueSet The venues to probe.
    /// @return hints The per-venue probe hints, zero-filled when unsupplied.
    function _resolveVenueSet(address[] calldata venues, uint256[] calldata probeHints)
        internal
        view
        returns (address[] memory venueSet, uint256[] memory hints)
    {
        if (venues.length == 0) {
            require(probeHints.length == 0, ArrayLengthMismatch());
            uint256 n = whitelistedVenueCount();
            // An empty whitelist yields no candidates, which `_waterfall`
            // turns into a single coalesced Uniswap leg. That is deliberately
            // the same outcome as naming a list whose every entry is dead or
            // non-whitelisted: both mean "no propAMM can price this order",
            // and reverting on one while silently routing the other would
            // make identical economics behave differently.
            require(n <= MAX_SPLIT_VENUES, TooManyVenues(n));
            venueSet = new address[](n);
            for (uint256 i = 0; i < n; i++) {
                venueSet[i] = whitelistedVenueAt(i);
            }
            hints = new uint256[](n);
        } else {
            require(venues.length <= MAX_SPLIT_VENUES, TooManyVenues(venues.length));
            require(probeHints.length == 0 || probeHints.length == venues.length, ArrayLengthMismatch());
            venueSet = venues;
            if (probeHints.length == venues.length) {
                hints = probeHints;
            } else {
                hints = new uint256[](venues.length);
            }
        }
    }

    /// @notice Quote phase + planning for `swapSplitV1`.
    /// @dev Quotes run while this contract holds the pulled `amountIn`, so the
    /// R1 snapshot-delta invariant brackets them: the balance is snapshotted
    /// after the pull and required to be EXACTLY equal afterwards, so any
    /// venue quote that net-consumes in-flight user funds reverts the whole
    /// call. The check is `==` and not `>= amountIn` on purpose — pre-existing
    /// router dust would otherwise mask a theft of the same size.
    ///
    /// The flip side of `==` is that a balance INCREASE across the quote phase
    /// also reverts. That is intended for a venue that pushes tokens mid-quote
    /// (nothing legitimate does), but it makes the split path incompatible with
    /// a `tokenIn` whose balances move on their own — rebasing and
    /// reflection/fee-redistribution tokens can credit this contract while a
    /// quote is in flight and revert an honest split. Do not whitelist venues
    /// for such tokens, or route them through `swapV1` instead.
    ///
    /// The check sits after `_waterfall`, not after `_gatherCandidates`, so
    /// that it covers EVERY quote taken while the funds are held — including
    /// the Uniswap reference quotes `_waterfall` takes through
    /// `fallbackQuoter`. Those are admin config rather than caller input, so
    /// this is defence in depth, but a bracket that stops short of some of
    /// the quotes it claims to cover is worse than no claim at all.
    /// `sortByRateDesc` is pure, so ordering the candidates first changes
    /// nothing about what the invariant observes.
    /// @param venueSet The venues to probe.
    /// @param hints The per-venue probe hints (0 = none).
    /// @param tokenIn_ The resolved ERC-20 being sold.
    /// @param tokenOut_ The resolved ERC-20 being bought.
    /// @param amountIn The total input the returned legs must sum to.
    /// @param maxLegs The maximum number of propAMM legs.
    /// @return legs The planned legs, summing to `amountIn`.
    function _planSplit(
        address[] memory venueSet,
        uint256[] memory hints,
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn,
        uint256 maxLegs
    ) internal returns (IPropAMMRouter.Leg[] memory legs) {
        uint256 snap = IERC20(tokenIn_).balanceOf(address(this));

        SplitPlanner.Candidate[] memory cands = _gatherCandidates(venueSet, hints, tokenIn_, tokenOut_, amountIn);

        SplitPlanner.sortByRateDesc(cands);
        legs = _waterfall(cands, tokenIn_, tokenOut_, amountIn, maxLegs);

        require(IERC20(tokenIn_).balanceOf(address(this)) == snap, QuoteBalanceInvariantViolated());
    }

    /// @dev One candidate per venue, sized at `min(hint or amountIn,
    /// amountIn)`: the partial-fill extension when the venue advertises it
    /// (ERC165), else a two-point probe at that size and half it, with τ-band
    /// saturation detection and a bounded downward probe when both points
    /// come back saturated. Dead venues (both points revert or zero) and
    /// absurd quotes (out > uint128.max, which would overflow the rate
    /// comparisons) yield no candidate. Duplicates are deduped.
    /// @param venueSet The venues to probe.
    /// @param hints The per-venue probe hints (0 = none).
    /// @param tokenIn_ The resolved ERC-20 being sold.
    /// @param tokenOut_ The resolved ERC-20 being bought.
    /// @param amountIn The total input being split.
    /// @return cands The live candidates, unsorted.
    function _gatherCandidates(
        address[] memory venueSet,
        uint256[] memory hints,
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn
    ) internal returns (SplitPlanner.Candidate[] memory cands) {
        SplitPlanner.Candidate[] memory tmp = new SplitPlanner.Candidate[](venueSet.length);
        uint256 count = 0;
        for (uint256 i = 0; i < venueSet.length; i++) {
            bool dup = false;
            for (uint256 j = 0; j < i; j++) {
                if (venueSet[j] == venueSet[i]) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            (uint256 fill, uint256 out) = _probeVenue(venueSet[i], hints[i], tokenIn_, tokenOut_, amountIn);
            if (fill == 0 || out == 0 || out > type(uint128).max) continue;
            tmp[count++] = SplitPlanner.Candidate({venue: venueSet[i], fill: fill, out: out});
        }
        cands = new SplitPlanner.Candidate[](count);
        for (uint256 i = 0; i < count; i++) {
            cands[i] = tmp[i];
        }
    }

    /// @dev Extension path or two-point probe for one venue. Probe points:
    /// p = min(hint or amountIn, amountIn) and p/2. Failure legend: a
    /// reverting, zero, or oversized quote at a point is a dead point; both
    /// dead → no candidate; one alive → that point; both alive and EQUAL →
    /// saturated at both, resolved by `_probeDownToFillable`; both alive and
    /// unequal → the τ-band saturation test picks full vs half.
    /// Membership is checked HERE rather than relying on `quoteVenueV1`'s
    /// `_isVenue` gate: the extension branch calls `quotePartialFill` directly,
    /// so without this the router would execute arbitrary caller-supplied code
    /// (an address whose `supportsInterface` returns true) while holding the
    /// pulled funds, and that address could return a maximal quote to sweep the
    /// ranking and starve the real venues. Non-members are skipped, matching
    /// the documented "venues that revert while quoting — including
    /// non-whitelisted addresses — are skipped" behavior of the other paths.
    /// @param venue The venue to probe.
    /// @param hint The caller's probe size for this venue (0 = none).
    /// @param tokenIn_ The resolved ERC-20 being sold.
    /// @param tokenOut_ The resolved ERC-20 being bought.
    /// @param amountIn The total input being split (the probe's upper bound).
    /// @return fill The input size this venue is a candidate for.
    /// @return out The `tokenOut` that `fill` was quoted to yield.
    function _probeVenue(address venue, uint256 hint, address tokenIn_, address tokenOut_, uint256 amountIn)
        internal
        returns (uint256 fill, uint256 out)
    {
        if (!_isVenue(venue)) return (0, 0);

        // The probe size bounds BOTH paths. Feeding the extension the full
        // `amountIn` while the two-point probe honored the hint would make a
        // hint meant to bound exposure to this venue do the opposite: the
        // venue would be offered the whole order and could claim all of it.
        uint256 p = hint == 0 || hint > amountIn ? amountIn : hint;

        if (ERC165Checker.supportsInterface(venue, type(IPropAMMPartialFill).interfaceId)) {
            try IPropAMMPartialFill(venue).quotePartialFill(tokenIn_, tokenOut_, p) returns (
                uint256 fillable, uint256 amountOut_
            ) {
                // A venue reporting more than it was offered has broken this
                // interface's `fillableAmountIn <= amountIn` requirement.
                // Clamping the fill while keeping `amountOut_` — which was
                // quoted for the LARGER size — would read its rate as
                // `amountOut_ / p`, inflated by exactly the over-report,
                // letting it sweep the ranking and starve honest venues
                // before failing its own leg. A venue that breaks the
                // requirement has told us its quote means nothing, so the
                // candidate is discarded rather than rescaled.
                if (fillable > p) return (0, 0);
                return (fillable, amountOut_);
            } catch {
                return (0, 0);
            }
        }

        // An out-of-range quote is discarded HERE, before it is used: it feeds
        // `isSaturated`, whose `out * BPS` would overflow and revert the whole
        // split — a griefing vector any single whitelisted venue could aim at
        // every other caller's split, including ones not naming it.
        uint256 outFull = _tryQuote(venue, tokenIn_, tokenOut_, p);
        if (outFull > type(uint128).max) outFull = 0;
        uint256 half = p / 2;
        if (half == 0) return (p, outFull);
        uint256 outHalf = _tryQuote(venue, tokenIn_, tokenOut_, half);
        if (outHalf > type(uint128).max) outHalf = 0;

        if (outFull == 0 && outHalf == 0) return (0, 0);
        if (outFull == 0) return (half, outHalf);
        if (outHalf == 0) return (p, outFull);
        // Equal outputs mean the venue is saturated at the half point as well,
        // so `half` is NOT a size it fills — it must be resolved downward.
        if (outFull == outHalf) return _probeDownToFillable(venue, tokenIn_, tokenOut_, half, outFull);
        if (SplitPlanner.isSaturated(outFull, outHalf)) return (half, outHalf);
        return (p, outFull);
    }

    /// @dev Resolves a venue that quoted the same output at both probe points.
    /// A flat quote across `[half, p]` means the venue's capacity lies below
    /// `half`, so neither point can be used as a leg size: a saturating venue
    /// ACCEPTS an oversized input, delivers only its ceiling, and keeps the
    /// difference. `proRataMin` cannot catch that — the leg's floor would be
    /// derived from the very quote that is flat — and neither can the
    /// reference cutoff, which a venue whose ceiling beats Uniswap clears.
    ///
    /// So halve down looking for a size that quotes STRICTLY below the
    /// ceiling. Such a size is provably under the venue's capacity, which
    /// makes it a size the venue fills in full. If the budget runs out the
    /// venue gets no candidate at all. That is deliberately conservative: it
    /// forgoes a quote that may look attractive, in exchange for never
    /// handing a venue input it will not fill. A caller who knows a venue's
    /// true capacity can still reach it precisely with `probeHints`.
    /// @param venue The venue to probe.
    /// @param tokenIn_ The resolved ERC-20 being sold.
    /// @param tokenOut_ The resolved ERC-20 being bought.
    /// @param from The probe size to start halving from (the half point).
    /// @param ceiling The saturated output both earlier points returned.
    /// @return fill A size this venue demonstrably fills, or 0.
    /// @return out The `tokenOut` that `fill` was quoted to yield, or 0.
    function _probeDownToFillable(address venue, address tokenIn_, address tokenOut_, uint256 from, uint256 ceiling)
        internal
        returns (uint256 fill, uint256 out)
    {
        uint256 size = from;
        for (uint256 i = 0; i < SplitPlanner.MAX_SATURATION_STEPS; i++) {
            size /= 2;
            if (size == 0) return (0, 0);
            uint256 outAt = _tryQuote(venue, tokenIn_, tokenOut_, size);
            if (outAt == 0 || outAt > type(uint128).max) return (0, 0);
            if (outAt < ceiling) return (size, outAt);
        }
        return (0, 0);
    }

    /// @dev A single venue quote that reports failure as zero instead of
    /// reverting. Routed through `this.quoteVenueV1` so the try/catch has an
    /// external call boundary and every venue type (incl. the fallback and
    /// Bebop branches) is priced by the same code as production quoting. Safe
    /// under `nonReentrant` because `quoteVenueV1` carries no guard.
    /// @param venue The venue to quote.
    /// @param tokenIn_ The resolved ERC-20 being sold.
    /// @param tokenOut_ The resolved ERC-20 being bought.
    /// @param amount The input size to quote.
    /// @return out The quoted `tokenOut`, or 0 if the venue could not price it.
    function _tryQuote(address venue, address tokenIn_, address tokenOut_, uint256 amount)
        internal
        returns (uint256 out)
    {
        try this.quoteVenueV1(venue, tokenIn_, tokenOut_, amount) returns (uint256 amountOut_, address) {
            out = amountOut_;
        } catch {
            out = 0;
        }
    }

    /// @dev Assigns up to `maxLegs` prop legs in rate order, gated by the
    /// Uniswap reference rate quoted at the residual lower bound. The
    /// amountIn/100 floor on that reference size is best-effort, not a
    /// guarantee: it stops a dust-sized residual from rounding the reference
    /// rate to zero, but for an `amountIn` under 100 wei the floor is itself
    /// zero-ish and Uniswap quotes 0, which disables the cutoff entirely and
    /// lets every candidate through. That is the same by-design behavior as a
    /// fallback that cannot be priced at all, and it is benign: each leg still
    /// carries its own pro-rata `minOut` and the aggregate `amountOutMin` still
    /// gates the swap. On the first contested candidate the reference
    /// is refined ONCE at the true prospective fallback size. The remainder
    /// becomes a fallback leg (minOut 0 — `_executeLegs` derives the
    /// shortfall min). Per-leg minimums are the pro-rata share of the RANKING
    /// quote, never a fresh quote at the final leg size: a requote is a price
    /// an adversarial venue gets to pick after it has already won.
    /// @param cands The candidates, pre-sorted by descending rate.
    /// @param tokenIn_ The resolved ERC-20 being sold.
    /// @param tokenOut_ The resolved ERC-20 being bought.
    /// @param amountIn The total input the legs must sum to.
    /// @param maxLegs The maximum number of propAMM legs. Only the
    /// automatically appended coalesced remainder leg is exempt — it is the
    /// safety net, not a planning choice. A `fallbackSwapRouter` address the
    /// caller listed in `venues` is ranked like any other candidate and DOES
    /// consume a slot (it is then merged into the coalesced swap by
    /// `_executeLegs`).
    /// @return legs The planned legs, summing to `amountIn`.
    function _waterfall(
        SplitPlanner.Candidate[] memory cands,
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn,
        uint256 maxLegs
    ) internal returns (IPropAMMRouter.Leg[] memory legs) {
        // No candidates means no cutoff comparison will ever run, so the
        // reference quote below would be dead. It is not free: `_tryQuote`
        // against the fallback router reaches `IQuoterV2.quoteExactInputSingle`,
        // which simulates a full pool swap and reverts internally. This is the
        // documented outcome for an empty whitelist and for a venue list whose
        // every entry is dead or de-listed, so it is worth short-circuiting.
        if (cands.length == 0) {
            legs = new IPropAMMRouter.Leg[](1);
            legs[0] = IPropAMMRouter.Leg({venue: fallbackSwapRouter, amountIn: amountIn, minOut: 0});
            return legs;
        }

        uint256 residualLb = amountIn;
        for (uint256 i = 0; i < cands.length; i++) {
            residualLb = cands[i].fill >= residualLb ? 0 : residualLb - cands[i].fill;
        }
        uint256 refSize = residualLb > amountIn / 100 ? residualLb : amountIn / 100;
        if (refSize == 0) refSize = 1;
        // Clamped like the probe quotes so `refOut * fill` below is provably
        // in range, leaving no unbounded product for a reader to reason about.
        // The quoter is trusted admin config, so this is hygiene, not a
        // control: a zero reference is already the "cannot price the fallback"
        // path, which simply lets every candidate through the cutoff.
        uint256 refOut = _tryQuote(fallbackSwapRouter, tokenIn_, tokenOut_, refSize);
        if (refOut > type(uint128).max) refOut = 0;

        IPropAMMRouter.Leg[] memory tmp = new IPropAMMRouter.Leg[](cands.length + 1);
        uint256 legCount = 0;
        uint256 remaining = amountIn;
        bool refined = false;

        for (uint256 i = 0; i < cands.length && remaining > 0 && legCount < maxLegs; i++) {
            // contested: rate_v <= uniRate  <=>  out * refSize <= refOut * fill
            if (cands[i].out * refSize <= refOut * cands[i].fill) {
                if (refined) break;
                refined = true;
                refSize = remaining;
                refOut = _tryQuote(fallbackSwapRouter, tokenIn_, tokenOut_, refSize);
                if (refOut > type(uint128).max) refOut = 0;
                if (cands[i].out * refSize <= refOut * cands[i].fill) break;
            }
            // NOTE on staleness: candidates after the refinement are still
            // compared against `(refSize, refOut)` sized for the residual as
            // it stood at the refining candidate, which is LARGER than their
            // own prospective residual. Uniswap's unit rate degrades with
            // size, so the stale reference is a LOOSER cutoff: it can admit a
            // candidate marginally worse than the true Uniswap rate, never
            // reject a better one. Bounded economic slippage, and every
            // admitted leg still carries its own pro-rata `minOut` while the
            // aggregate `amountOutMin` gates the swap. Re-quoting per
            // candidate would cost a pool simulation each and is not worth it.
            uint256 leg = cands[i].fill >= remaining ? remaining : cands[i].fill;
            tmp[legCount++] = IPropAMMRouter.Leg({
                venue: cands[i].venue, amountIn: leg, minOut: SplitPlanner.proRataMin(cands[i].out, cands[i].fill, leg)
            });
            remaining -= leg;
        }

        if (remaining > 0) {
            tmp[legCount++] = IPropAMMRouter.Leg({venue: fallbackSwapRouter, amountIn: remaining, minOut: 0});
        }

        legs = new IPropAMMRouter.Leg[](legCount);
        for (uint256 i = 0; i < legCount; i++) {
            legs[i] = tmp[i];
        }
    }

    /// @dev Validates leg count, per-leg venue membership and non-zero
    /// amounts; returns the total input to pull. Venues are validated up
    /// front (revert before pulling funds) rather than relying on
    /// `_dispatchVenue`'s whitelist check, which inside the per-leg
    /// `try/catch` would silently convert an unknown venue into a fallback
    /// leg.
    function _validateLegs(IPropAMMRouter.Leg[] calldata legs) internal view returns (uint256 totalIn) {
        require(legs.length >= 1 && legs.length <= MAX_SPLIT_VENUES, InvalidLegCount(legs.length));
        for (uint256 i = 0; i < legs.length; i++) {
            require(_isVenue(legs[i].venue), UnknownVenue());
            require(legs[i].amountIn > 0, ZeroAmount());
            totalIn += legs[i].amountIn;
        }
    }

    /// @dev Pulls `amountIn` of `tokenIn` from the caller (wrapping ETH when
    /// `tokenIn` is the sentinel) and returns the resolved ERC-20 the swap
    /// legs will actually sell. Mirrors `_coreSwap`'s pull block.
    function _pullFunds(address tokenIn, uint256 amountIn) internal returns (address tokenIn_) {
        tokenIn_ = tokenIn;
        if (tokenIn == ETH_SENTINEL) {
            require(msg.value == amountIn, InvalidValue(amountIn, msg.value));
            IWETH(WETH).deposit{value: msg.value}();
            tokenIn_ = WETH;
        } else {
            require(msg.value == 0, InvalidValue(0, msg.value));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }
    }

    /// @notice Runs a list of legs with funds already held by this contract.
    /// @dev Legs naming the fallback router and legs whose venue fails are
    /// coalesced into ONE Uniswap V3 swap at the end, whose floor is the
    /// largest of:
    ///  (a) the aggregate shortfall vs `amountOutMin` (saturating —
    ///      over-delivering prop legs must not underflow). BEST-EFFORT ONLY:
    ///      it is zero whenever the prop legs that succeeded already clear
    ///      `amountOutMin`, which is the normal outcome of splitting into
    ///      better-than-Uniswap venues.
    ///  (b) the sum of the explicit fallback legs' `minOut`. DILUTED when
    ///      failed prop legs merge into the same swap: their `amountIn`
    ///      joins the slice contributing no floor, so requiring only
    ///      `sum(minOut)` over `explicitIn + failedIn` amounts to a rate of
    ///      `sum(minOut) / (explicitIn + failedIn)` — looser than the
    ///      `sum(minOut) / explicitIn` the caller asked for. This is left
    ///      unscaled on purpose. Scaling the floor up over the merged slice
    ///      is UNSOUND: `minOut` states a rate the caller priced at the
    ///      explicit legs' size, Uniswap's unit rate falls with size, and so
    ///      the scaled floor exceeds what an honest pool returns for the
    ///      larger slice and reverts good swaps (a 1k leg priced at its own
    ///      ~0.999 rate, scaled over a 1M merged slice, demands ~999k from a
    ///      pool that honestly yields ~500k). Only (c) closes the failed
    ///      portion. A failed PROP leg's `minOut` is excluded for a separate
    ///      reason — priced off a better venue (see `swapMultiLegV1`).
    ///  (c) the caller's `fallbackMinOut` — the only term that is neither
    ///      derived from this swap's own accounting nor inferable from an
    ///      onchain quote, and so the only one that survives a sandwich.
    /// Emits one `Swapped` per executed leg, naming `swapFor` so the events
    /// attribute the swap to the user even when legs deliver to the router.
    /// `tokenIn` is the caller-visible token (sentinel allowed, for events);
    /// `tokenIn_` is the resolved ERC-20 being sold.
    function _executeLegs(IPropAMMRouter.Leg[] memory legs, LegRun memory r) internal returns (uint256 delivered) {
        address tokenOut_ = r.tokenOut;
        address recipient_ = r.payTo;
        if (r.tokenOut == ETH_SENTINEL) {
            tokenOut_ = WETH;
            recipient_ = address(this);
        }
        require(r.tokenIn_ != tokenOut_, IdenticalTokens());

        uint256 fbAmount = 0;
        uint256 fbMinOut = 0;
        for (uint256 i = 0; i < legs.length; i++) {
            if (legs[i].venue == fallbackSwapRouter) {
                fbAmount += legs[i].amountIn;
                fbMinOut += legs[i].minOut;
                continue;
            }
            uint256 prevBal = IERC20(tokenOut_).balanceOf(recipient_);
            try this._dispatchVenue(
                legs[i].venue, r.tokenIn_, tokenOut_, legs[i].amountIn, legs[i].minOut, recipient_, r.deadline, prevBal
            ) returns (
                uint256 legOut
            ) {
                delivered += legOut;
                _emitSwapped(legs[i].venue, r.tokenIn, r.tokenOut, legs[i].amountIn, legOut, r.swapFor);
            } catch {
                fbAmount += legs[i].amountIn;
            }
        }

        if (fbAmount > 0) {
            // (a) Best-effort: zero once the surviving prop legs clear the
            // aggregate min. See this function's NatSpec.
            uint256 uniMin = delivered >= r.amountOutMin ? 0 : r.amountOutMin - delivered;
            // (b) The explicit fallback legs' floor, unscaled. It is DILUTED
            // when failed prop legs merge into the same swap — see this
            // function's NatSpec — and deliberately left that way: scaling it
            // up over the merged slice would extend a rate the caller stated
            // for a SMALLER size, and Uniswap's unit rate falls with size, so
            // the scaled floor over-demands and reverts honest swaps.
            if (fbMinOut > uniMin) uniMin = fbMinOut;
            // (c) The caller's own floor on this slice — the only one that
            // survives a sandwich. (a) and (b) are derived from the swap's own
            // accounting, and any floor derived instead from an onchain quote
            // would be read from the same pool in the same transaction, so an
            // attacker moving that pool moves the floor with it.
            if (r.fallbackMinOut > uniMin) uniMin = r.fallbackMinOut;
            uint256 prevBal = IERC20(tokenOut_).balanceOf(recipient_);
            UniV3Router.swapExactIn(
                r.tokenIn_,
                tokenOut_,
                resolvedFee(r.tokenIn_, tokenOut_),
                fbAmount,
                uniMin,
                recipient_,
                fallbackSwapRouter
            );
            uint256 fbOut = IERC20(tokenOut_).balanceOf(recipient_) - prevBal;
            require(fbOut >= uniMin, InsufficientOutput(uniMin, fbOut));
            delivered += fbOut;
            _emitSwapped(fallbackSwapRouter, r.tokenIn, r.tokenOut, fbAmount, fbOut, r.swapFor);
        }

        require(delivered >= r.amountOutMin, InsufficientOutput(r.amountOutMin, delivered));

        if (r.tokenOut == ETH_SENTINEL) {
            // Unwrapped to `payTo`, not `swapFor`: the fee variants must
            // receive the gross themselves before disbursing.
            _sendWrappedETH(r.payTo, delivered);
        }
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

        if (venue == BEBOP_ROUTER) {
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
        (bestQuote, venue) = _pickBestVenue(tokenIn, tokenOut, amount);
        require(bestQuote > 0, NoQuotesAvailable());
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Gates on `_isVenue` (a whitelisted propAMM or the fallback),
    /// reverting `UnknownVenue` otherwise.
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

        // The asked venue. Kept for retro-compatibility.
        quotedVenue = venue;

        if (venue == fallbackSwapRouter) {
            amountOut =
                UniV3Router.quoteExactIn(tokenIn, tokenOut, resolvedFee(tokenIn, tokenOut), amount, fallbackQuoter);
        } else if (venue == BEBOP_ROUTER) {
            amountOut = IBebopRouter(BEBOP_ROUTER).quote(tokenIn, tokenOut, amount);
        } else {
            // Any other whitelisted venue speaks the common `IPropAMM` interface.
            amountOut = IPropAMM(venue).quote(tokenIn, tokenOut, amount);
        }
    }

    /// @inheritdoc IPropAMMRouter
    /// @dev Delegates to `_pickBestVenueFrom`, considering ONLY `venues`. Venues
    /// that revert while quoting — including non-whitelisted addresses, which
    /// `quoteVenueV1` rejects with `UnknownVenue` — are skipped, not surfaced.
    /// When none of `venues` can be priced, it reverts `NoQuotesAvailable`.
    function quoteSelectedVenuesV1(address[] calldata venues, address tokenIn, address tokenOut, uint256 amountIn)
        public
        returns (uint256 bestAmountOut, address bestVenue)
    {
        (bestAmountOut, bestVenue) = _pickBestVenueFrom(venues, tokenIn, tokenOut, amountIn);
        if (bestVenue == address(0)) {
            revert NoQuotesAvailable();
        }
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
            try this.quoteVenueV1(candidate, tokenIn, tokenOut, amount) returns (
                uint256 amountOut, address _quotedVenue
            ) {
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
        try this.quoteVenueV1(fallbackSwapRouter, tokenIn, tokenOut, amount) returns (
            uint256 amountOut, address _quotedVenue
        ) {
            if (amountOut > bestQuote) {
                bestQuote = amountOut;
                venue = fallbackSwapRouter;
            }
        } catch {}
    }

    /// @notice Finds the venue offering the best `tokenOut` for `amount` of
    /// `tokenIn` among a caller-supplied set of venues.
    /// @dev Quotes ONLY the provided `venues` (each via `this.quoteVenueV1`
    /// in its own `try/catch`), so a venue that reverts — including a
    /// non-whitelisted address, which `quoteVenueV1` rejects with
    /// `UnknownVenue` — is simply skipped. Unlike `_pickBestVenue`, it does NOT seed or
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
            try this.quoteVenueV1(venues[i], tokenIn, tokenOut, amount) returns (
                uint256 amountOut, address _quotedVenue
            ) {
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
    /// `VenueAlreadyWhitelisted` if it is already listed. Other than the
    /// built-in propAMMs Bebop, (which use their bespoke interface), a venue is expected
    /// to implement the common `IPropAMM` interface. Listing an address that does
    /// not (an EOA, the wrong contract, a not-yet-deployed adapter) is not a
    /// foot-gun: its `quote`/`swap` calls revert, so it is skipped by selection
    /// and, on an explicit swap, the reverting `_dispatchVenue` rolls back and the
    /// Uniswap fallback engages — no funds are stranded.
    ///
    /// IMPORTANT — interaction with `swapSplitV1`'s whitelist mode. Growing the
    /// whitelist past `MAX_SPLIT_VENUES` makes `swapSplitV1` / `swapSplitWithFeeV1`
    /// revert `TooManyVenues` for calls that pass an EMPTY `venues` array (the
    /// "probe the whole whitelist" convenience). Callers naming venues explicitly
    /// are unaffected, as is every other entrypoint — `swapV1` / `quoteV1` keep
    /// iterating the full whitelist. The revert is deliberate: `EnumerableSet`
    /// ordering is unstable across removals, so silently probing "the first eight"
    /// would make the split's venue set nondeterministic. This function does NOT
    /// cap the whitelist, because doing so would limit the protocol's venue roster
    /// to eight for the benefit of one optional convenience path. Check
    /// {isSplitWhitelistModeAvailable} before and after listing, and migrate
    /// integrators to explicit `venues` lists before crossing the bound.
    /// @param venue The venue address to whitelist.
    function addVenue(address venue) external restricted {
        _addVenue(venue);
    }

    /// @notice Whether `swapSplitV1` / `swapSplitWithFeeV1` still accept an empty
    /// `venues` array (the "probe the whole whitelist" convenience).
    /// @dev False once `whitelistedVenueCount()` exceeds `MAX_SPLIT_VENUES`, at
    /// which point those calls revert `TooManyVenues` and callers must name their
    /// venues explicitly. Exposed so admins can check before {addVenue} and
    /// integrators can detect the mode without simulating a swap. See {addVenue}
    /// for why the whitelist itself is not capped.
    /// @return available True while the empty-`venues` split path is usable.
    function isSplitWhitelistModeAvailable() external view returns (bool available) {
        return whitelistedVenueCount() <= MAX_SPLIT_VENUES;
    }

    /// @dev Whitelist-insertion core behind the public `addVenue`. Reverts
    /// `ZeroAddress` if `venue` is zero and `VenueAlreadyWhitelisted` if it is
    /// already listed; emits `VenueWhitelisted` on success.
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
