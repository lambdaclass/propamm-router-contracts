// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {PRIO_UPDATE_REGISTRY} from "../test/interfaces/IPrioUpdateRegistry.sol";
import {ForkGate} from "./helpers/ForkGate.sol";

/// @notice Real-venue execution gas on a mainnet fork, for the entrypoints the
/// mock benchmark (`GasBench.t.sol`) can only approximate.
///
/// The obstacle this has to solve first: registry-priced venues publish pricing
/// lanes just-in-time, so at any given block most of them revert `0x666a2814`.
/// Discovery recovers each venue's last published lane timestamp from the
/// storage its own quote reads, then warps there. Because a warp is global, two
/// venues are only simultaneously quotable if their lanes overlap in time --
/// which is what caps the reachable leg count.
contract RealGasForkTest is ForkGate {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant ONE_YEAR = 365 days;
    uint256 constant PROBE = 1_000e6;

    address[6] VENUES = [
        0x5979458912F80B96d30D4220af8E2e4925A33320, // Fermi
        0x71e790dd841c8A9061487cb3E78C288E75cE0B3d, // Kipseli
        0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76,
        0x00000003f1ec2379e79F58E12EC6C4F51Ee92149,
        0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB,
        0x217d58931A8549ca539426AA8152E33dAfc3d95A
    ];

    PropAMMRouter router;
    address taker = makeAddr("taker");

    function setUp() public {
        if (!_selectForkOrSkip()) return;
        AccessManager m = new AccessManager(address(this));
        PropAMMRouter impl = new PropAMMRouter();
        router = PropAMMRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(PropAMMRouter.initialize, (UNISWAP_ROUTER_02, UNISWAP_QUOTER_V2, address(m)))
                    )
                ))
        );
        for (uint256 i = 0; i < 6; i++) {
            router.addVenue(VENUES[i]);
        }
        _fund(taker, 20_000_000e6);
        vm.prank(taker);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.deal(taker, 10 ether);
    }

    /// @dev Machine-readable line for `scripts/gas/split_economics.py`.
    function _emit(string memory key, uint256 v) internal pure {
        console2.log(string.concat("RESULT|", key, "|", vm.toString(v)));
    }

    function _fund(address who, uint256 amt) internal {
        vm.store(USDC, keccak256(abi.encode(who, USDC_BALANCES_SLOT)), bytes32(amt));
    }

    function _quotes(address v) internal returns (bool ok) {
        try router.quoteVenueV1(v, USDC, WETH, PROBE) returns (uint256 out, address) {
            ok = out > 0;
        } catch {
            ok = false;
        }
    }

    /// @dev How many of the six quote at the CURRENT timestamp.
    function _liveCount() internal returns (uint256 n) {
        for (uint256 i = 0; i < 6; i++) {
            if (_quotes(VENUES[i])) n++;
        }
    }

    /// @dev Candidate lane timestamps recovered from the registry storage that
    /// venue `v`'s own quote touches.
    function _candidates(address v) internal returns (uint256[] memory out) {
        vm.record();
        _quotes(v);
        (bytes32[] memory reads,) = vm.accesses(PRIO_UPDATE_REGISTRY);
        uint256[] memory buf = new uint256[](reads.length * 29);
        uint256 n = 0;
        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 word = vm.load(PRIO_UPDATE_REGISTRY, reads[i]);
            for (uint256 off = 0; off <= 28; off++) {
                uint32 c = uint32(bytes4(word << (off * 8)));
                if (c == 0 || c > block.timestamp) continue;
                if (block.timestamp - c > ONE_YEAR) continue;
                buf[n++] = c;
            }
        }
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = buf[i];
        }
    }

    function test_discoverQuotableVenueSets() public {
        uint256 t0 = block.timestamp;
        console2.log("fork block", block.number);
        console2.log("fork timestamp", t0);
        console2.log("venues quotable at head:", _liveCount());
        console2.log("");

        // Gather every plausible lane timestamp any venue's quote reads.
        uint256[] memory all = new uint256[](0);
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(t0);
            uint256[] memory c = _candidates(VENUES[i]);
            console2.log("venue", i, "lane candidates:", c.length);
            uint256[] memory merged = new uint256[](all.length + c.length);
            for (uint256 j = 0; j < all.length; j++) {
                merged[j] = all[j];
            }
            for (uint256 j = 0; j < c.length; j++) {
                merged[all.length + j] = c[j];
            }
            all = merged;
        }
        console2.log("total candidate timestamps:", all.length);
        console2.log("");

        // For each candidate, how many venues quote simultaneously?
        uint256 best = 0;
        uint256 bestTs = 0;
        for (uint256 i = 0; i < all.length; i++) {
            vm.warp(all[i]);
            uint256 n = _liveCount();
            if (n > best) {
                best = n;
                bestTs = all[i];
                console2.log("  new best: venues", n, "at ts", all[i]);
            }
        }
        console2.log("");
        console2.log("MAX SIMULTANEOUSLY QUOTABLE VENUES:", best);
        console2.log("at timestamp:", bestTs);
        if (bestTs != 0) {
            vm.warp(bestTs);
            for (uint256 i = 0; i < 6; i++) {
                if (_quotes(VENUES[i])) console2.log("   quotable:", VENUES[i]);
            }
        }
    }

    // ---- real-venue gas report -------------------------------------------

    uint256 constant LEG = 5_000e6; // per-leg USDC; small enough that 4 legs
    // plus warm-up runs stay well inside Fermi's inventory

    address constant FERMI = 0x5979458912F80B96d30D4220af8E2e4925A33320;

    /// @dev Warp to Fermi's recoverable lane. Returns false (and skips) if it
    /// cannot be recovered at this fork block.
    function _makeFermiQuotable() internal returns (bool) {
        if (_quotes(FERMI)) return true;
        uint256[] memory c = _candidates(FERMI);
        for (uint256 i = 0; i < c.length; i++) {
            vm.warp(c[i]);
            if (_quotes(FERMI)) return true;
        }
        vm.skip(true, "Fermi's lane not recoverable at this fork block -- market staleness, not a router bug");
        return false;
    }

    function _dupVenues(uint256 n) internal pure returns (address[] memory v) {
        v = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            v[i] = FERMI;
        }
    }

    /// @dev n legs of LEG each, all on Fermi. `swapMultiLegV1` permits
    /// duplicate venues, which is what makes a real multi-leg measurement
    /// possible when only one venue on mainnet is ever quotable at a time.
    function _dupLegs(uint256 n) internal pure returns (IPropAMMRouter.Leg[] memory legs) {
        legs = new IPropAMMRouter.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = IPropAMMRouter.Leg({venue: FERMI, amountIn: LEG, minOut: 0});
        }
    }

    function _mlReal(uint256 n) internal returns (uint256 g) {
        IPropAMMRouter.Leg[] memory legs = _dupLegs(n);
        vm.startPrank(taker);
        uint256 s = gasleft();
        router.swapMultiLegV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300);
        g = s - gasleft();
        vm.stopPrank();
    }

    function _mlFeeReal(uint256 n) internal returns (uint256 g) {
        IPropAMMRouter.Leg[] memory legs = _dupLegs(n);
        IPropAMMRouter.FrontendFee memory fee = IPropAMMRouter.FrontendFee({bps: 50, recipient: address(0xFEE)});
        vm.startPrank(taker);
        uint256 s = gasleft();
        router.swapMultiLegWithFeeV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300, fee);
        g = s - gasleft();
        vm.stopPrank();
    }

    /// @dev n venues QUOTED (all Fermi), one executed. Isolates real quote cost.
    function _selReal(uint256 n) internal returns (uint256 g) {
        address[] memory v = _dupVenues(n);
        vm.startPrank(taker);
        uint256 s = gasleft();
        router.swapViaSelectedVenuesV1(v, USDC, WETH, LEG, 0, taker, block.timestamp + 300);
        g = s - gasleft();
        vm.stopPrank();
    }

    /// @dev swapSplitV1 dedupes its venue set, so only ONE real prop leg is
    /// reachable; the rest of the order becomes the coalesced Uniswap leg.
    function _splitReal(uint256 amountIn) internal returns (uint256 g) {
        address[] memory v = _dupVenues(1);
        uint256[] memory h = new uint256[](1);
        h[0] = LEG;
        vm.startPrank(taker);
        uint256 s = gasleft();
        router.swapSplitV1(v, h, USDC, WETH, amountIn, 0, 0, 8, taker, block.timestamp + 300);
        g = s - gasleft();
        vm.stopPrank();
    }

    function _quoteGas(address venue, uint256 amt) internal returns (uint256 g) {
        uint256 s = gasleft();
        try router.quoteVenueV1(venue, USDC, WETH, amt) returns (uint256, address) {} catch {}
        g = s - gasleft();
    }

    function test_realVenueGasReport() public {
        if (!_makeFermiQuotable()) return;
        console2.log("fork block", block.number);
        console2.log("warped to Fermi lane ts", block.timestamp);
        console2.log("per-leg size (USDC 6dp)", LEG);
        console2.log("");

        // --- real component costs -----------------------------------------
        console2.log("=== REAL COMPONENT QUOTE GAS ===");
        _quoteGas(FERMI, LEG);
        console2.log("Fermi quote (warm)          ", _quoteGas(FERMI, LEG));
        _quoteGas(UNISWAP_ROUTER_02, LEG);
        console2.log("Uniswap QuoterV2 @5k USDC   ", _quoteGas(UNISWAP_ROUTER_02, LEG));
        console2.log("Uniswap QuoterV2 @100k USDC ", _quoteGas(UNISWAP_ROUTER_02, 100_000e6));
        console2.log("Uniswap QuoterV2 @1M USDC   ", _quoteGas(UNISWAP_ROUTER_02, 1_000_000e6));
        console2.log("");

        // --- warm every shape ---------------------------------------------
        for (uint256 n = 2; n <= 4; n++) {
            _mlReal(n);
            _mlFeeReal(n);
            _selReal(n);
        }
        _splitReal(LEG * 2);

        uint256[5] memory ml;
        uint256[5] memory mlf;
        uint256[5] memory sel;
        for (uint256 n = 2; n <= 4; n++) {
            ml[n] = _mlReal(n);
            mlf[n] = _mlFeeReal(n);
            sel[n] = _selReal(n);
        }
        uint256 sp1 = _splitReal(LEG * 2);

        console2.log("=== MEASURED, REAL VENUE (Fermi) ===");
        for (uint256 n = 2; n <= 4; n++) {
            console2.log("--- legs:", n);
            console2.log("  swapMultiLegV1        ", ml[n]);
            console2.log("  swapMultiLegWithFeeV1 ", mlf[n]);
            console2.log("  selectedVenues (quoted)", sel[n]);
        }
        console2.log("");
        console2.log("swapSplitV1, 1 real prop leg + Uniswap remainder", sp1);
        console2.log("");
        console2.log("=== REAL MARGINALS ===");
        for (uint256 n = 3; n <= 4; n++) {
            console2.log("  multileg  per added real leg  ", int256(ml[n]) - int256(ml[n - 1]));
            console2.log("  selected  per added real quote", int256(sel[n]) - int256(sel[n - 1]));
        }
    }

    // ---- simulated future: several venues publishing in the same block ----
    //
    // Today at most one venue has a fresh PrioUpdateRegistry lane at any
    // block, which caps a real split at one prop leg. The intended steady
    // state is several venues publishing often enough to be simultaneously
    // quotable. To measure THAT, patch each venue's lane timestamp forward to
    // the current block instead of warping time back to the lane -- the exact
    // inverse of `_candidates`.
    //
    // Why this keeps the gas honest: every contract involved is the real
    // deployed bytecode and every code path is the production one. The only
    // difference from a genuinely fresh lane is the value of one storage word,
    // and a freshness comparison costs the same gas whichever way it resolves.
    // What is NOT honest is the PRICE: each venue quotes off its last
    // published lane, which may be hours stale, so the routing DECISION here
    // is not economically meaningful. Gas is; price is not.

    /// @dev Replace the 4-byte window at byte offset `off` of `word` with `val`.
    function _patchWindow(bytes32 word, uint256 off, uint32 val) internal pure returns (bytes32) {
        uint256 shift = (28 - off) * 8;
        uint256 mask = uint256(0xFFFFFFFF) << shift;
        return bytes32((uint256(word) & ~mask) | (uint256(val) << shift));
    }

    /// @dev Make `v` quotable AT THE CURRENT TIMESTAMP by ageing its lane
    /// forward. Tries each plausible timestamp window in the registry slots the
    /// venue's own quote reads, keeping the first patch that works and undoing
    /// the ones that do not. Slots already locked in by an earlier venue are
    /// never restored, so venues cannot clobber each other.
    function _forceFresh(address v, bytes32[] memory locked, uint256 lockedN)
        internal
        returns (bool ok, bytes32 usedSlot)
    {
        if (_quotes(v)) return (true, bytes32(0));

        vm.record();
        _quotes(v);
        (bytes32[] memory reads,) = vm.accesses(PRIO_UPDATE_REGISTRY);
        uint32 now32 = uint32(block.timestamp);

        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 orig = vm.load(PRIO_UPDATE_REGISTRY, reads[i]);
            bool isLocked = false;
            for (uint256 k = 0; k < lockedN; k++) {
                if (locked[k] == reads[i]) isLocked = true;
            }
            for (uint256 off = 0; off <= 28; off++) {
                uint32 c = uint32(bytes4(orig << (off * 8)));
                if (c == 0 || c > block.timestamp) continue;
                if (block.timestamp - c > ONE_YEAR) continue;
                vm.store(PRIO_UPDATE_REGISTRY, reads[i], _patchWindow(orig, off, now32));
                if (_quotes(v)) return (true, reads[i]);
                if (!isLocked) vm.store(PRIO_UPDATE_REGISTRY, reads[i], orig);
            }
        }
        return (false, bytes32(0));
    }

    /// @dev Force as many venues fresh as possible at the current timestamp.
    function _forceAllFresh() internal returns (uint256 n, address[] memory fresh) {
        bytes32[] memory locked = new bytes32[](6);
        uint256 lockedN = 0;
        address[] memory buf = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            (bool ok, bytes32 slot) = _forceFresh(VENUES[i], locked, lockedN);
            if (ok) {
                buf[n++] = VENUES[i];
                if (slot != bytes32(0)) locked[lockedN++] = slot;
            }
        }
        fresh = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            fresh[i] = buf[i];
        }
    }

    function _quoteOrZero(address v, uint256 amt) internal returns (uint256 out) {
        try router.quoteVenueV1(v, USDC, WETH, amt) returns (uint256 o, address) {
            out = o;
        } catch {
            out = 0;
        }
    }

    function test_simulateMultiVenueQuotable() public {
        console2.log("fork block", block.number);
        console2.log("venues quotable before patching:", _liveCount());
        (uint256 n, address[] memory fresh) = _forceAllFresh();
        console2.log("venues quotable AFTER patching: ", n);
        console2.log("");

        uint256[5] memory ladder = [uint256(1_000e6), 2_500e6, 5_000e6, 10_000e6, 25_000e6];
        console2.log("=== WETH out per venue, by order size (0 = cannot price) ===");
        for (uint256 i = 0; i < n; i++) {
            console2.log("venue", fresh[i]);
            for (uint256 j = 0; j < 5; j++) {
                console2.log("   size / out", ladder[j], _quoteOrZero(fresh[i], ladder[j]));
            }
        }
        console2.log("=== Uniswap V3 reference ===");
        for (uint256 j = 0; j < 5; j++) {
            console2.log("   size / out", ladder[j], _quoteOrZero(UNISWAP_ROUTER_02, ladder[j]));
        }
        console2.log("");
        console2.log("=== how many venues can price each size ===");
        for (uint256 j = 0; j < 5; j++) {
            uint256 c = 0;
            for (uint256 i = 0; i < n; i++) {
                if (_quoteOrZero(fresh[i], ladder[j]) > 0) c++;
            }
            console2.log("   size / venues", ladder[j], c);
        }
    }

    uint256 constant MLEG = 2_500e6; // every fresh venue can price this size

    function _mlMulti(address[] memory vs, uint256 n) internal returns (uint256 g) {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = IPropAMMRouter.Leg({venue: vs[i], amountIn: MLEG, minOut: 0});
        }
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapMultiLegV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    function _selMulti(address[] memory vs, uint256 n) internal returns (uint256 g) {
        address[] memory sub = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            sub[i] = vs[i];
        }
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapViaSelectedVenuesV1(sub, USDC, WETH, MLEG, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    /// @dev Returns gas and the number of Swapped events, which is the number
    /// of legs that actually executed -- the split's rate cutoff decides that,
    /// not the caller.
    function _splitMulti(address[] memory vs, uint256 n) internal returns (uint256 g, uint256 legs) {
        address[] memory sub = new address[](n);
        uint256[] memory h = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sub[i] = vs[i];
            h[i] = MLEG;
        }
        vm.recordLogs();
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapSplitV1(sub, h, USDC, WETH, MLEG * n, 0, 0, 8, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
        for (uint256 i = 0; i < lg.length; i++) {
            if (lg[i].emitter == address(router) && lg[i].topics[0] == topic) legs++;
        }
    }

    function test_realMultiVenueGas() public {
        (uint256 nf, address[] memory fresh) = _forceAllFresh();
        console2.log("fork block", block.number);
        console2.log("venues forced fresh:", nf);
        console2.log("leg size (USDC 6dp)", MLEG);
        require(nf >= 4, "need 4 fresh venues");
        console2.log("");

        // warm every shape at every count
        for (uint256 n = 2; n <= 4; n++) {
            _forceAllFresh();
            _mlMulti(fresh, n);
            _forceAllFresh();
            _selMulti(fresh, n);
            _forceAllFresh();
            _splitMulti(fresh, n);
        }

        uint256[5] memory ml;
        uint256[5] memory sel;
        uint256[5] memory sp;
        uint256[5] memory spLegs;
        for (uint256 n = 2; n <= 4; n++) {
            _forceAllFresh();
            ml[n] = _mlMulti(fresh, n);
            _forceAllFresh();
            sel[n] = _selMulti(fresh, n);
            _forceAllFresh();
            (sp[n], spLegs[n]) = _splitMulti(fresh, n);
        }

        console2.log("=== REAL, DISTINCT VENUES ===");
        for (uint256 n = 2; n <= 4; n++) {
            console2.log("--- venues:", n);
            console2.log("  swapMultiLegV1 (n real legs) ", ml[n]);
            console2.log("  swapViaSelectedVenuesV1      ", sel[n]);
            console2.log("  swapSplitV1                  ", sp[n]);
            console2.log("     ^ legs actually executed  ", spLegs[n]);
        }
        console2.log("");
        console2.log("=== MARGINALS ===");
        for (uint256 n = 3; n <= 4; n++) {
            console2.log("  multileg per real leg  ", int256(ml[n]) - int256(ml[n - 1]));
            console2.log("  selected per real quote", int256(sel[n]) - int256(sel[n - 1]));
            console2.log("  split    per real venue", int256(sp[n]) - int256(sp[n - 1]));
        }
    }

    // ---- single-venue cost, and an ISOLATED per-venue probe cost ----------
    //
    // The earlier multi-venue run varied `amountIn` with the venue count, so
    // its "per venue" marginal also contained the Uniswap reference quote
    // growing with order size. Here `amountIn` is held CONSTANT and only the
    // number of probed venues varies, so the marginal is the probe alone.

    uint256 constant FIXED_IN = 10_000e6; // constant: keeps the reference quote fixed
    uint256 constant HINT = 2_500e6; // constant per-venue probe size

    function _viaVenue(address v, uint256 amt) internal returns (uint256 g) {
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapViaVenueV1(v, USDC, WETH, amt, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    function _ml1(address v, uint256 amt) internal returns (uint256 g) {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](1);
        legs[0] = IPropAMMRouter.Leg({venue: v, amountIn: amt, minOut: 0});
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapMultiLegV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    /// @dev n venues probed, CONSTANT amountIn and constant per-venue hint.
    function _splitFixed(address[] memory vs, uint256 n) internal returns (uint256 g, uint256 legs) {
        address[] memory sub = new address[](n);
        uint256[] memory h = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sub[i] = vs[i];
            h[i] = HINT;
        }
        vm.recordLogs();
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapSplitV1(sub, h, USDC, WETH, FIXED_IN, 0, 0, 8, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
        for (uint256 i = 0; i < lg.length; i++) {
            if (lg[i].emitter == address(router) && lg[i].topics[0] == topic) legs++;
        }
    }

    function test_singleVenueAndIsolatedProbeCost() public {
        (uint256 nf, address[] memory fresh) = _forceAllFresh();
        require(nf >= 4, "need 4 fresh venues");
        console2.log("fork block", block.number);
        console2.log("");

        console2.log("=== SINGLE-VENUE SWAP, 2,500 USDC -> WETH ===");
        for (uint256 i = 0; i < nf; i++) {
            _forceAllFresh();
            _viaVenue(fresh[i], HINT); // warm
            _forceAllFresh();
            uint256 g = _viaVenue(fresh[i], HINT);
            _forceAllFresh();
            uint256 q = _quoteGas(fresh[i], HINT);
            // `swapViaVenueV1` does NOT quote -- it goes straight to
            // `_coreSwap`/`_dispatchVenue` -- so `g` is already pull + execute
            // + event with no quote in it. The quote is reported separately
            // because it is what the QUOTING entrypoints add on top.
            console2.log("venue", fresh[i]);
            console2.log("   swapViaVenueV1 (no quote)", g);
            console2.log("   one quote, separately    ", q);
            console2.log("   quote+execute would be   ", g + q);
        }
        _forceAllFresh();
        _viaVenue(UNISWAP_ROUTER_02, HINT);
        _forceAllFresh();
        console2.log("Uniswap V3 via swapViaVenueV1", _viaVenue(UNISWAP_ROUTER_02, HINT));
        console2.log("");

        console2.log("=== FERMI: three ways to route ONE leg, 2,500 USDC ===");
        _forceAllFresh();
        _viaVenue(FERMI, HINT);
        _forceAllFresh();
        console2.log("swapViaVenueV1 (caller names it)", _viaVenue(FERMI, HINT));
        _forceAllFresh();
        _ml1(FERMI, HINT);
        _forceAllFresh();
        console2.log("swapMultiLegV1 1 leg            ", _ml1(FERMI, HINT));
        console2.log("");

        console2.log("=== ISOLATED PROBE COST: constant amountIn 10k, constant hint 2.5k ===");
        uint256[6] memory sp;
        uint256[6] memory lg2;
        for (uint256 n = 1; n <= 4; n++) {
            _forceAllFresh();
            _splitFixed(fresh, n); // warm
            _forceAllFresh();
            (sp[n], lg2[n]) = _splitFixed(fresh, n);
            console2.log("  venues probed", n);
            console2.log("     gas          ", sp[n]);
            console2.log("     Swapped events (prop legs + coalesced)", lg2[n]);
        }
        console2.log("");
        console2.log("=== TRUE per-probed-venue marginal (constant order size) ===");
        for (uint256 n = 2; n <= 4; n++) {
            console2.log("   adding venue #", n);
            console2.log("     marginal     ", int256(sp[n]) - int256(sp[n - 1]));
        }
    }

    // ---- every method, one basis: move exactly 10,000 USDC -> WETH --------

    uint256 constant ORDER = 10_000e6;

    function _sel(address[] memory vs, uint256 n, uint256 amt) internal returns (uint256 g) {
        address[] memory sub = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            sub[i] = vs[i];
        }
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapViaSelectedVenuesV1(sub, USDC, WETH, amt, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    function _swapV1(uint256 amt) internal returns (uint256 g) {
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapV1(USDC, WETH, amt, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    function _mlSplitEven(address[] memory vs, uint256 n, uint256 amt) internal returns (uint256 g) {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](n);
        for (uint256 i = 0; i < n; i++) {
            legs[i] = IPropAMMRouter.Leg({venue: vs[i], amountIn: amt / n, minOut: 0});
        }
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapMultiLegV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    function _spEven(address[] memory vs, uint256 n, uint256 amt) internal returns (uint256 g, uint256 ev) {
        address[] memory sub = new address[](n);
        uint256[] memory h = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sub[i] = vs[i];
            h[i] = amt / n;
        }
        vm.recordLogs();
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapSplitV1(sub, h, USDC, WETH, amt, 0, 0, 8, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bytes32 t = keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
        for (uint256 i = 0; i < lg.length; i++) {
            if (lg[i].emitter == address(router) && lg[i].topics[0] == t) ev++;
        }
    }

    function test_allMethodsSameOrder() public {
        (uint256 nf, address[] memory fresh) = _forceAllFresh();
        require(nf >= 4, "need 4 fresh venues");
        console2.log("=== ALL METHODS, 10,000 USDC -> WETH, fork block", block.number);
        console2.log("");

        _forceAllFresh();
        _viaVenue(FERMI, ORDER);
        _forceAllFresh();
        uint256 gFermi = _viaVenue(FERMI, ORDER);
        console2.log("swapViaVenueV1 -> Fermi        ", gFermi);
        _emit("gas_viaVenue_fermi", gFermi);
        _forceAllFresh();
        _viaVenue(UNISWAP_ROUTER_02, ORDER);
        _forceAllFresh();
        uint256 gUni = _viaVenue(UNISWAP_ROUTER_02, ORDER);
        console2.log("swapViaVenueV1 -> Uniswap V3   ", gUni);
        _emit("gas_viaVenue_uniswap", gUni);
        _forceAllFresh();
        _swapV1(ORDER);
        _forceAllFresh();
        uint256 gSwapV1 = _swapV1(ORDER);
        console2.log("swapV1 (quotes all 6)          ", gSwapV1);
        _emit("gas_swapV1", gSwapV1);
        console2.log("");

        for (uint256 n = 2; n <= 4; n++) {
            _forceAllFresh();
            _sel(fresh, n, ORDER);
            _forceAllFresh();
            uint256 a = _sel(fresh, n, ORDER);
            _forceAllFresh();
            _mlSplitEven(fresh, n, ORDER);
            _forceAllFresh();
            uint256 b = _mlSplitEven(fresh, n, ORDER);
            _forceAllFresh();
            _spEven(fresh, n, ORDER);
            _forceAllFresh();
            (uint256 c, uint256 ev) = _spEven(fresh, n, ORDER);
            console2.log("--- n =", n);
            console2.log("  swapViaSelectedVenuesV1  ", a);
            console2.log("  swapMultiLegV1           ", b);
            console2.log("  swapSplitV1              ", c);
            console2.log("     Swapped events        ", ev);
            _emit(string.concat("gas_selectedVenues_n", vm.toString(n)), a);
            _emit(string.concat("gas_multiLeg_n", vm.toString(n)), b);
            _emit(string.concat("gas_split_n", vm.toString(n)), c);
            _emit(string.concat("split_events_n", vm.toString(n)), ev);
        }
    }

    // ---- 1,000,000 USDC: where QuoterV2 and venue capacity both bite ------

    uint256 constant BIG = 1_000_000e6;

    /// @dev Split with no hints: each venue is probed at the FULL order size,
    /// which is what a caller who supplies no capacity picture gets. Above a
    /// venue's cap the quote saturates, and `_probeDownToFillable` then spends
    /// up to MAX_SATURATION_STEPS extra quotes hunting a fillable size.
    function _spNoHints(address[] memory vs, uint256 n, uint256 amt) internal returns (uint256 g, uint256 ev) {
        address[] memory sub = new address[](n);
        uint256[] memory noh = new uint256[](0);
        for (uint256 i = 0; i < n; i++) {
            sub[i] = vs[i];
        }
        vm.recordLogs();
        vm.startPrank(taker);
        uint256 st = gasleft();
        router.swapSplitV1(sub, noh, USDC, WETH, amt, 0, 0, 8, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bytes32 t = keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
        for (uint256 i = 0; i < lg.length; i++) {
            if (lg[i].emitter == address(router) && lg[i].topics[0] == t) ev++;
        }
    }

    function _refund() internal {
        _fund(taker, 30_000_000e6);
    }

    function test_splitAtOneMillion() public {
        (uint256 nf, address[] memory fresh) = _forceAllFresh();
        require(nf >= 4, "need 4 fresh venues");
        console2.log("=== 1,000,000 USDC -> WETH ===");
        console2.log("");

        console2.log("--- how many venues can price each size ---");
        uint256[4] memory sizes = [uint256(250_000e6), 333_333e6, 500_000e6, BIG];
        for (uint256 j = 0; j < 4; j++) {
            uint256 c = 0;
            for (uint256 i = 0; i < nf; i++) {
                if (_quoteOrZero(fresh[i], sizes[j]) > 0) c++;
            }
            console2.log("   size / venues able to price", sizes[j], c);
        }
        console2.log("");
        console2.log("QuoterV2 @1M USDC", _quoteGas(UNISWAP_ROUTER_02, BIG));
        console2.log("");

        uint256 snap = vm.snapshotState();

        _refund();
        _forceAllFresh();
        _viaVenue(UNISWAP_ROUTER_02, BIG);
        _refund();
        _forceAllFresh();
        console2.log("swapViaVenueV1 -> Uniswap (floor)", _viaVenue(UNISWAP_ROUTER_02, BIG));
        vm.revertToState(snap);

        _refund();
        _forceAllFresh();
        _swapV1(BIG);
        _refund();
        _forceAllFresh();
        console2.log("swapV1 (quotes all 6)            ", _swapV1(BIG));
        vm.revertToState(snap);

        for (uint256 n = 2; n <= 4; n++) {
            _refund();
            _forceAllFresh();
            _mlSplitEven(fresh, n, BIG);
            _refund();
            _forceAllFresh();
            uint256 a = _mlSplitEven(fresh, n, BIG);
            console2.log("swapMultiLegV1 n legs", n);
            console2.log("   gas", a);
            vm.revertToState(snap);
        }
        console2.log("");

        console2.log("--- swapSplitV1, HINTED (legs pre-sized to 1M/n) ---");
        for (uint256 n = 1; n <= 4; n++) {
            _refund();
            _forceAllFresh();
            _spEven(fresh, n, BIG);
            _refund();
            _forceAllFresh();
            (uint256 g, uint256 ev) = _spEven(fresh, n, BIG);
            console2.log("   venues", n);
            console2.log("     gas           ", g);
            console2.log("     Swapped events", ev);
            vm.revertToState(snap);
        }
        console2.log("");

        console2.log("--- swapSplitV1, NO HINTS (probes at full 1M) ---");
        for (uint256 n = 1; n <= 4; n++) {
            _refund();
            _forceAllFresh();
            _spNoHints(fresh, n, BIG);
            _refund();
            _forceAllFresh();
            (uint256 g, uint256 ev) = _spNoHints(fresh, n, BIG);
            console2.log("   venues", n);
            console2.log("     gas           ", g);
            console2.log("     Swapped events", ev);
            vm.revertToState(snap);
        }
    }

    // ---- capacity re-check: has any venue gained depth? -------------------

    uint256[9] LADDER = [
        uint256(100_000e6),
        250_000e6,
        500_000e6,
        750_000e6,
        1_000_000e6,
        1_500_000e6,
        2_000_000e6,
        3_000_000e6,
        5_000_000e6
    ];

    function test_capacityRecheck() public {
        uint256 t0 = block.timestamp;
        console2.log("fork block", block.number);
        console2.log("timestamp ", t0);
        console2.log("quotable BEFORE any patching:", _liveCount());
        console2.log("");

        // Uniswap first: always live, and it is the benchmark every venue is
        // judged against.
        console2.log("=== Uniswap V3 reference ladder ===");
        uint256[9] memory uni;
        for (uint256 j = 0; j < 9; j++) {
            uni[j] = _quoteOrZero(UNISWAP_ROUTER_02, LADDER[j]);
            console2.log("   size / WETH out", LADDER[j], uni[j]);
        }
        console2.log("");

        for (uint256 i = 0; i < 6; i++) {
            vm.warp(t0);
            uint256[] memory c = _candidates(VENUES[i]);
            bool ok = false;
            uint256 usedTs = 0;
            for (uint256 j = 0; j < c.length && !ok; j++) {
                vm.warp(c[j]);
                if (_quotes(VENUES[i])) {
                    ok = true;
                    usedTs = c[j];
                }
            }
            console2.log("--- venue", VENUES[i]);
            if (!ok) {
                console2.log("      lane NOT recoverable at this block");
                continue;
            }
            uint256 age = t0 > usedTs ? t0 - usedTs : 0;
            console2.log("      lane age, seconds", age);
            uint256 cap = 0;
            for (uint256 j = 0; j < 9; j++) {
                uint256 o = _quoteOrZero(VENUES[i], LADDER[j]);
                if (o == 0) {
                    console2.log("      cannot price", LADDER[j]);
                    break;
                }
                // bp advantage over Uniswap at this size (0 if worse)
                int256 bp = uni[j] == 0 ? int256(0) : (int256(o) - int256(uni[j])) * 10_000 / int256(uni[j]);
                console2.log("      size", LADDER[j]);
                console2.log("        WETH out", o);
                console2.log("        vs Uniswap, bp", bp);
                cap = LADDER[j];
                if (j > 0) {
                    // saturation: output did not grow with a bigger order
                    uint256 oPrev = _quoteOrZero(VENUES[i], LADDER[j - 1]);
                    if (o <= oPrev) {
                        console2.log("        SATURATED -- flat vs previous size");
                        cap = LADDER[j - 1];
                        break;
                    }
                }
            }
            console2.log("      usable depth at least, USDC", cap);
            _emit(string.concat("depth_usdc6_venue", vm.toString(i)), cap);
        }
    }

    // ---- with Fermi deep, which route actually wins? ----------------------
    //
    // METHODOLOGY LIMIT: real venues have finite inventory, and a warm-up run
    // CONSUMES it. So the warm-then-measure discipline used everywhere else in
    // this file cannot be applied at order sizes near a venue's capacity --
    // the measured call would hit a drained venue. Delivery and routing are
    // therefore measured with single clean calls (correct amounts, cold gas),
    // and warm gas at these sizes is simply not obtainable this way.

    address constant FERMI2 = 0x5979458912F80B96d30D4220af8E2e4925A33320;

    function _fermiLane() internal returns (bool) {
        if (_quotes(FERMI2)) return true;
        uint256[] memory c = _candidates(FERMI2);
        for (uint256 i = 0; i < c.length; i++) {
            vm.warp(c[i]);
            if (_quotes(FERMI2)) return true;
        }
        return false;
    }

    function _splitOne(uint256 amt) internal returns (uint256 g, uint256 ev, uint256 out) {
        address[] memory v = new address[](1);
        v[0] = FERMI2;
        uint256[] memory noh = new uint256[](0);
        vm.recordLogs();
        vm.startPrank(taker);
        uint256 st = gasleft();
        out = router.swapSplitV1(v, noh, USDC, WETH, amt, 0, 0, 8, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bytes32 t = keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
        for (uint256 i = 0; i < lg.length; i++) {
            if (lg[i].emitter == address(router) && lg[i].topics[0] == t) ev++;
        }
    }

    function _twoLeg(uint256 fermiPart, uint256 uniPart) internal returns (uint256 g, uint256 out) {
        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = IPropAMMRouter.Leg({venue: FERMI2, amountIn: fermiPart, minOut: 0});
        legs[1] = IPropAMMRouter.Leg({venue: router.fallbackSwapRouter(), amountIn: uniPart, minOut: 0});
        vm.startPrank(taker);
        uint256 st = gasleft();
        out = router.swapMultiLegV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300);
        g = st - gasleft();
        vm.stopPrank();
    }

    function _countSwapped() internal returns (uint256 n) {
        Vm.Log[] memory lg = vm.getRecordedLogs();
        bytes32 t = keccak256("Swapped(address,address,address,uint256,uint256,address,address)");
        for (uint256 i = 0; i < lg.length; i++) {
            if (lg[i].emitter == address(router) && lg[i].topics[0] == t) n++;
        }
    }

    /// @dev Which venue each Swapped event names, so a silent fallback is visible.
    function test_diagnoseRoutes() public {
        require(_fermiLane(), "lane");
        uint256 snap = vm.snapshotState();
        address fb = router.fallbackSwapRouter();
        console2.log("fallbackSwapRouter", fb);
        console2.log("FERMI             ", FERMI2);
        console2.log("");

        uint256[2] memory sizes = [uint256(1_000_000e6), 2_000_000e6];
        for (uint256 i = 0; i < 2; i++) {
            uint256 amt = sizes[i];
            console2.log("=== order ===", amt);
            console2.log("  Fermi quote at this size ", _quoteOrZero(FERMI2, amt));
            console2.log("  Uniswap quote at this size", _quoteOrZero(UNISWAP_ROUTER_02, amt));

            // Fermi only
            _fund(taker, 60_000_000e6);
            vm.recordLogs();
            vm.startPrank(taker);
            (uint256 o1,) = router.swapViaVenueV1(FERMI2, USDC, WETH, amt, 0, taker, block.timestamp + 300);
            vm.stopPrank();
            uint256 n1 = _countSwapped();
            console2.log("  swapViaVenueV1 -> Fermi delivered", o1);
            console2.log("     events", n1);
            vm.revertToState(snap);
            require(_fermiLane(), "lane");

            // two-leg: Fermi 1.5M cap + Uniswap remainder (only when it splits)
            if (amt > 1_500_000e6) {
                _fund(taker, 60_000_000e6);
                IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
                legs[0] = IPropAMMRouter.Leg({venue: FERMI2, amountIn: 1_500_000e6, minOut: 0});
                legs[1] = IPropAMMRouter.Leg({venue: fb, amountIn: amt - 1_500_000e6, minOut: 0});
                vm.recordLogs();
                vm.startPrank(taker);
                uint256 o2 = router.swapMultiLegV1(legs, USDC, WETH, 0, 0, taker, block.timestamp + 300);
                vm.stopPrank();
                uint256 n2 = _countSwapped();
                console2.log("  multileg Fermi1.5M+Uni delivered", o2);
                console2.log("     events", n2);
                console2.log("     (Fermi alone at 1.5M would be", _quoteOrZero(FERMI2, 1_500_000e6));
                vm.revertToState(snap);
                require(_fermiLane(), "lane");
            }
            console2.log("");
        }
    }
}
