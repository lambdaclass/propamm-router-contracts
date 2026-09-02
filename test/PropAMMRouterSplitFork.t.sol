// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {PRIO_UPDATE_REGISTRY, IPrioUpdateRegistry} from "../test/interfaces/IPrioUpdateRegistry.sol";

/// @notice Deploys the NEW router implementation behind a proxy on a mainnet
/// fork, whitelists the live Fermi venue, and executes a real 1,000,000 USDC
/// -> WETH split through `swapSplitV1` (Fermi's measured capacity is ~500k
/// USDC, so the split should produce a Fermi leg plus a Uniswap remainder
/// leg).
///
/// Unlike pinning a price slot / timestamp from one historical mainnet
/// transaction, this test DISCOVERS Fermi's currently-published pricing lane
/// instead. Proprietary venues like Fermi publish just-in-time pricing into
/// the `PrioUpdateRegistry`, and Fermi rotates its pricing contract on
/// redeploy, so a pinned target/slot bit-rots and the quote starts reverting
/// `0x666a2814` ("lane empty/stale"). A pinned test would then fail not
/// because of a router bug but because market data from months ago is, of
/// course, stale.
///
/// Instead: try a small quote first; if it reverts, `vm.record()` the
/// storage a retried quote touches on the `PrioUpdateRegistry`, scan every
/// word read for a 4-byte window that looks like a recent unix timestamp,
/// and `vm.warp` to each candidate in turn until Fermi quotes successfully.
/// That recovers the venue's own last real published lane without pinning
/// anything. If no candidate works the test `vm.skip`s (not fails) — a fork
/// test failing because a market maker did not publish a price is noise, not
/// signal.
///
/// Skipped in CI: needs a live RPC and, ideally, a Fermi venue that has
/// published recently (not guaranteed even with a live RPC — see above).
/// Run locally:
///   RPC_URL=<mainnet rpc> forge test --match-contract PropAMMRouterSplitForkTest -vv
contract PropAMMRouterSplitForkTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant FERMI = 0x5979458912F80B96d30D4220af8E2e4925A33320;
    uint256 constant USDC_BALANCES_SLOT = 9;

    uint256 constant SPLIT_AMOUNT = 1_000_000e6; // above Fermi's ~500k measured cap
    uint256 constant FERMI_MEASURED_CAP = 500_000e6; // Phase 0 measurement; sizes the remainder floor
    uint256 constant FALLBACK_TOLERANCE_BPS = 100; // 1% slack on the remainder floor
    uint256 constant BPS = 10_000;
    uint256 constant PROBE_AMOUNT = 1_000e6; // small size, only used to test quotability
    uint256 constant ONE_YEAR = 365 days;

    // Above-cap search: double from CAP_SEARCH_START until the quote goes
    // flat, giving up at CAP_SEARCH_MAX. Flat means "saturated": the venue
    // returns the same output for twice the input.
    uint256 constant CAP_SEARCH_START = 100_000e6;
    uint256 constant CAP_SEARCH_MAX = 12_800_000e6;
    // Slack allowed when converting delivered WETH back into the USDC the
    // venue must have filled. Covers price curvature between the small
    // reference probe and the real fill size, plus rounding.
    uint256 constant FILL_SLACK_BPS = 200;

    PropAMMRouter router;
    address taker = makeAddr("taker");

    function setUp() public {
        vm.skip(true); // CI: no RPC / no guarantee a lane is quotable. Delete this line to run locally.
        vm.createSelectFork(vm.envOr("RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        AccessManager manager = new AccessManager(address(this));
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data =
            abi.encodeCall(PropAMMRouter.initialize, (UNISWAP_ROUTER_02, UNISWAP_QUOTER_V2, address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), data))));
        router.addVenue(FERMI);

        // Fund the taker with 1M USDC directly in storage (blacklist bit clear).
        _fundTaker(SPLIT_AMOUNT);
        vm.prank(taker);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.deal(taker, 1 ether);
    }

    /// @dev Sets the taker's USDC balance directly, bypassing the blacklist
    /// bit and any minting authority.
    function _fundTaker(uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(taker, USDC_BALANCES_SLOT)), bytes32(amount));
    }

    function test_split_fermiPlusUniswap_executes() public {
        bool fermiQuotable = _ensureFermiQuotable();

        (uint256 allUniQuote,) = router.quoteVenueV1(UNISWAP_ROUTER_02, USDC, WETH, SPLIT_AMOUNT);

        address[] memory venues = new address[](1);
        venues[0] = FERMI;
        uint256[] memory noHints = new uint256[](0);

        // `fallbackMinOut` matters here and must not be 0. Fermi beats Uniswap,
        // so its leg alone clears `amountOutMin` and the aggregate shortfall
        // term collapses to zero — leaving the ~500k USDC Uniswap remainder
        // unfloored if the caller passes nothing. A real integrator derives
        // this from an OFFCHAIN quote; the closest stand-in available inside a
        // fork test is the onchain quote for the prospective remainder size,
        // discounted for tolerance. That is NOT sandwich-proof (it reads the
        // same pool in the same transaction) and is used here only to exercise
        // the parameter end to end — see `swapSplitV1`'s NatSpec.
        uint256 remainderSize = SPLIT_AMOUNT - FERMI_MEASURED_CAP;
        (uint256 remainderQuote,) = router.quoteVenueV1(UNISWAP_ROUTER_02, USDC, WETH, remainderSize);
        uint256 fallbackMinOut = remainderQuote * (BPS - FALLBACK_TOLERANCE_BPS) / BPS;

        vm.prank(taker);
        uint256 amountOut = router.swapSplitV1(
            venues, noHints, USDC, WETH, SPLIT_AMOUNT, allUniQuote, fallbackMinOut, 8, taker, block.timestamp + 120
        );

        assertGe(amountOut, allUniQuote, "split should beat or match all-uniswap");
        assertEq(IERC20(WETH).balanceOf(taker), amountOut);

        // The entire economic claim of this feature: when Fermi actually
        // quotes, splitting into it must strictly beat routing everything
        // through Uniswap alone.
        if (fermiQuotable) {
            assertGt(amountOut, allUniQuote, "Fermi quoted so the split must strictly beat all-uniswap");
        }
    }

    /// @dev Ensures Fermi is quotable at `block.timestamp`, discovering its
    /// currently-published lane rather than pinning one. Tries a small quote
    /// as-is; on revert, records the storage a retried quote reads on the
    /// `PrioUpdateRegistry`, scans each word read for a 4-byte big-endian
    /// window whose value looks like a recent unix timestamp (in the past,
    /// within the last year), and `vm.warp`s to each candidate in turn until
    /// the quote succeeds — recovering Fermi's own last real publish time
    /// without touching any price data. Returns whether Fermi ended up
    /// quotable. If no candidate works, skips the test instead of failing it.
    function _ensureFermiQuotable() internal returns (bool) {
        if (_tryFermiQuote()) return true;

        vm.record();
        _tryFermiQuote();
        (bytes32[] memory reads,) = vm.accesses(PRIO_UPDATE_REGISTRY);

        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 word = vm.load(PRIO_UPDATE_REGISTRY, reads[i]);
            for (uint256 offset = 0; offset <= 28; offset++) {
                uint32 candidate = uint32(bytes4(word << (offset * 8)));
                if (candidate == 0 || candidate > block.timestamp) continue;
                if (block.timestamp - candidate > ONE_YEAR) continue;

                vm.warp(candidate);
                if (_tryFermiQuote()) return true;
            }
        }

        vm.skip(
            true,
            "Fermi's pricing lane could not be recovered at this fork block (no plausible recent timestamp found in the PrioUpdateRegistry state the quote touched) -- this is market-data staleness, not a router bug."
        );
        return false;
    }

    function _tryFermiQuote() internal returns (bool ok) {
        try router.quoteVenueV1(FERMI, USDC, WETH, PROBE_AMOUNT) returns (uint256 amountOut, address) {
            ok = amountOut > 0;
        } catch {
            ok = false;
        }
    }

    //-------------------------------------------------//
    // Above-cap swap behaviour (Phase 0 open question) //
    //-------------------------------------------------//

    /// @notice Answers the question the mocks had to guess at: when a real
    /// propAMM is handed MORE input than it can fill, does it revert, or does
    /// it accept the transfer, deliver only its ceiling output, and keep the
    /// difference?
    ///
    /// This matters because the router pays venues push-first
    /// (`_dispatchVenue` `safeTransfer`s `tokenIn`, then calls `swap`). If the
    /// venue reverts, the `try`/`catch` self-call rolls the transfer back and
    /// the Uniswap fallback runs — no harm. If instead it fills part and keeps
    /// the rest, the unfilled input is simply gone, and a per-leg `minOut`
    /// derived from that venue's own saturated quote cannot detect it (the
    /// quote is flat, so the floor is met trivially). That is the case
    /// `_probeDownToFillable` exists for, and whether it is load-bearing on
    /// mainnet or merely defensive depends entirely on this answer.
    ///
    /// Routed through `swapViaVenueV1` rather than a raw venue call on
    /// purpose: a bare `try FERMI.swap(...)` in the test frame would not roll
    /// back the test's own preceding `transfer`, so it could not distinguish
    /// the two branches at all. The router reproduces the exact production
    /// framing.
    function test_fermi_aboveCapSwap_retainsNoUnfilledInput() public {
        _ensureFermiQuotable();
        (uint256 aboveCap, uint256 ceilingOut) = _findAboveCapSize();

        _fundTaker(aboveCap);
        uint256 fermiUsdcBefore = IERC20(USDC).balanceOf(FERMI);
        uint256 takerWethBefore = IERC20(WETH).balanceOf(taker);

        // amountOutMin 0: this measures the VENUE, so the router must not be
        // the thing that rejects the oversized fill.
        vm.prank(taker);
        router.swapViaVenueV1(FERMI, USDC, WETH, aboveCap, 0, taker, block.timestamp + 120);

        uint256 fermiKept = IERC20(USDC).balanceOf(FERMI) - fermiUsdcBefore;
        uint256 wethOut = IERC20(WETH).balanceOf(taker) - takerWethBefore;
        assertGt(wethOut, 0, "swap delivered nothing through either venue");

        if (fermiKept == 0) {
            // Fermi rejected the oversized order and the Uniswap fallback ran.
            // `_probeDownToFillable` is then belt-and-braces on this venue.
            emit log("Fermi REVERTS above cap: oversized legs roll back, fallback covers them");
            return;
        }

        // Fermi took the input. Convert the WETH it delivered back into the
        // USDC it must have filled, priced off a small unsaturated quote, and
        // require that it kept no more than that.
        uint256 impliedFilled = _usdcImpliedBy(wethOut);
        emit log_named_uint("Fermi kept (USDC)", fermiKept);
        emit log_named_uint("Fermi filled (USDC, implied)", impliedFilled);
        // Fermi filled this itself, so it cannot have beaten the ceiling it
        // quoted for the same size.
        assertLe(wethOut, ceilingOut * (10_000 + FILL_SLACK_BPS) / 10_000, "delivery exceeded the quoted ceiling");
        assertLe(
            fermiKept,
            impliedFilled * (10_000 + FILL_SLACK_BPS) / 10_000,
            "Fermi ACCEPTED an above-cap order and kept input it did not fill -- _probeDownToFillable is load-bearing, not defensive"
        );
    }

    /// @notice The router-level consequence: planning an above-cap order must
    /// never size a Fermi leg past what Fermi will actually fill, whichever
    /// branch the test above lands in.
    function test_fermi_aboveCapSplit_sizesLegWithinFillableCapacity() public {
        _ensureFermiQuotable();
        (uint256 aboveCap,) = _findAboveCapSize();

        _fundTaker(aboveCap);
        uint256 fermiUsdcBefore = IERC20(USDC).balanceOf(FERMI);
        uint256 takerWethBefore = IERC20(WETH).balanceOf(taker);

        address[] memory venues = new address[](1);
        venues[0] = FERMI;
        uint256[] memory noHints = new uint256[](0);

        vm.prank(taker);
        uint256 amountOut =
            router.swapSplitV1(venues, noHints, USDC, WETH, aboveCap, 0, 0, 8, taker, block.timestamp + 120);

        uint256 fermiKept = IERC20(USDC).balanceOf(FERMI) - fermiUsdcBefore;
        assertEq(IERC20(WETH).balanceOf(taker) - takerWethBefore, amountOut, "reported output must match delivery");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router stranded input");

        if (fermiKept > 0) {
            assertLe(
                fermiKept,
                _usdcImpliedBy(amountOut) * (10_000 + FILL_SLACK_BPS) / 10_000,
                "planner handed Fermi more than it filled"
            );
        }
    }

    /// @dev Doubles the order size until Fermi's quote goes FLAT — the same
    /// output for twice the input, which is saturation — and returns that
    /// oversized size with the ceiling output it quoted. Skips rather than
    /// fails if no saturation shows up below `CAP_SEARCH_MAX`: a venue with
    /// deep inventory today is a market condition, not a router bug.
    /// @return aboveCap A size Fermi quotes but provably cannot fill entirely.
    /// @return ceilingOut The flat output Fermi quoted at that size.
    function _findAboveCapSize() internal returns (uint256 aboveCap, uint256 ceilingOut) {
        uint256 size = CAP_SEARCH_START;
        uint256 prevOut = _quoteFermiOrZero(size);

        while (size * 2 <= CAP_SEARCH_MAX) {
            uint256 next = size * 2;
            uint256 nextOut = _quoteFermiOrZero(next);

            // A quote that dies at the larger size is a hard cap: the venue
            // refuses to price it, so the router never builds a leg that big
            // and there is nothing to characterise here.
            if (nextOut == 0) {
                vm.skip(
                    true,
                    "Fermi stops quoting above its cap rather than saturating, so an above-cap FILL cannot be reached on this fork block."
                );
                return (0, 0);
            }
            if (prevOut > 0 && nextOut <= prevOut) return (next, nextOut);

            size = next;
            prevOut = nextOut;
        }

        vm.skip(
            true,
            "Fermi's quote never went flat below CAP_SEARCH_MAX at this fork block -- its inventory currently exceeds the search range."
        );
        return (0, 0);
    }

    /// @dev The USDC that `wethAmount` corresponds to at Fermi's small-size
    /// (unsaturated) rate. Used to turn "what was delivered" into "what must
    /// have been filled" without trusting a saturated quote.
    function _usdcImpliedBy(uint256 wethAmount) internal returns (uint256) {
        uint256 refOut = _quoteFermiOrZero(PROBE_AMOUNT);
        require(refOut > 0, "no unsaturated reference quote");
        return wethAmount * PROBE_AMOUNT / refOut;
    }

    function _quoteFermiOrZero(uint256 amountIn) internal returns (uint256 out) {
        try router.quoteVenueV1(FERMI, USDC, WETH, amountIn) returns (uint256 amountOut, address) {
            out = amountOut;
        } catch {
            out = 0;
        }
    }
}
