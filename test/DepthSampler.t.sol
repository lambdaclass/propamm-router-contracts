// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PRIO_UPDATE_REGISTRY} from "../test/interfaces/IPrioUpdateRegistry.sol";

/// @notice Samples venue depth and price advantage across MANY blocks, so the
/// economics rest on a distribution rather than one snapshot.
///
/// Why this exists: Fermi's usable depth moved ~3.6x in about 17 hours. Every
/// "is the split worth it" conclusion is conditioned on depth and basis-point
/// advantage, and a single-block reading of either is not evidence. Gas per
/// mechanism is durable and can be measured once; these two cannot.
///
/// It also measures the thing the patched-lane workaround was invented to get
/// around: how often are two or more venues NATURALLY quotable in the same
/// block? That frequency decides whether a real multi-venue split is reachable
/// at all, and it needs a denser sample than the six blocks checked by hand.
///
/// Runs against a real archive RPC, not the local anvil fork, because it hops
/// blocks. Set SAMPLES / STEP to trade runtime for resolution.
///   RPC_URL=<archive> forge test --match-path test/DepthSampler.t.sol -vv
contract DepthSamplerTest is Test {
    address constant LIVE_ROUTER = 0x4DdF368080CD7946db5b459aD591c350158175e1;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant FERMI = 0x5979458912F80B96d30D4220af8E2e4925A33320;
    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant ONE_YEAR = 365 days;
    uint256 constant PROBE = 1_000e6;

    address[6] VENUES = [
        0x5979458912F80B96d30D4220af8E2e4925A33320,
        0x71e790dd841c8A9061487cb3E78C288E75cE0B3d,
        0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76,
        0x00000003f1ec2379e79F58E12EC6C4F51Ee92149,
        0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB,
        0x217d58931A8549ca539426AA8152E33dAfc3d95A
    ];
    uint256[4] LADDER = [uint256(500_000e6), 1_000_000e6, 1_500_000e6, 2_000_000e6];

    IPropAMMRouter router = IPropAMMRouter(LIVE_ROUTER);

    function _q(address v, uint256 amt) internal returns (uint256 out) {
        try router.quoteVenueV1(v, USDC, WETH, amt) returns (uint256 o, address) {
            out = o;
        } catch {
            out = 0;
        }
    }

    /// @dev Quotable at THIS block's own timestamp -- no warping, no patching.
    /// This is what a real transaction at this block would have found.
    function _naturalCount() internal returns (uint256 n) {
        for (uint256 i = 0; i < 6; i++) {
            if (_q(VENUES[i], PROBE) > 0) n++;
        }
    }

    function _recoverFermi() internal returns (bool) {
        if (_q(FERMI, PROBE) > 0) return true;
        vm.record();
        _q(FERMI, PROBE);
        (bytes32[] memory reads,) = vm.accesses(PRIO_UPDATE_REGISTRY);
        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 w = vm.load(PRIO_UPDATE_REGISTRY, reads[i]);
            for (uint256 off = 0; off <= 28; off++) {
                uint32 c = uint32(bytes4(w << (off * 8)));
                if (c == 0 || c > block.timestamp) continue;
                if (block.timestamp - c > ONE_YEAR) continue;
                vm.warp(c);
                if (_q(FERMI, PROBE) > 0) return true;
            }
        }
        return false;
    }

    function _median(uint256[] memory a) internal pure returns (uint256) {
        if (a.length == 0) return 0;
        for (uint256 i = 1; i < a.length; i++) {
            uint256 k = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > k) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = k;
        }
        return a[a.length / 2];
    }

    function test_depthAndEdgeOverTime() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "set RPC_URL (archive) to run the sampler");
            return;
        }
        uint256 samples = vm.envOr("SAMPLES", uint256(10));
        uint256 step = vm.envOr("STEP", uint256(720)); // ~2.4h at 12s blocks

        vm.createSelectFork(rpc);
        uint256 head = block.number;
        console2.log("head block", head);
        console2.log("samples", samples);
        console2.log("step (blocks)", step);
        console2.log("span (blocks)", samples * step);
        console2.log("");

        uint256[] memory depths = new uint256[](samples);
        uint256[] memory bp1m = new uint256[](samples);
        uint256 multiFresh = 0;
        uint256 anyFresh = 0;
        uint256 fermiOk = 0;

        for (uint256 s = 0; s < samples; s++) {
            uint256 blk = head - (s * step);
            vm.createSelectFork(rpc, blk);
            // Kipseli's quote simulates a swap from the router's own balance.
            vm.store(USDC, keccak256(abi.encode(LIVE_ROUTER, USDC_BALANCES_SLOT)), bytes32(uint256(50_000_000e6)));

            uint256 nat = _naturalCount();
            if (nat >= 2) multiFresh++;
            if (nat >= 1) anyFresh++;

            if (!_recoverFermi()) {
                console2.log("block / natural-fresh / Fermi: unrecoverable", blk, nat);
                continue;
            }
            fermiOk++;

            uint256 depth = 0;
            uint256 prev = 0;
            for (uint256 j = 0; j < 4; j++) {
                uint256 o = _q(FERMI, LADDER[j]);
                if (o == 0 || (j > 0 && o <= prev)) break;
                prev = o;
                depth = LADDER[j];
            }
            depths[s] = depth;

            uint256 f = _q(FERMI, 1_000_000e6);
            uint256 u = _q(UNISWAP_ROUTER_02, 1_000_000e6);
            uint256 bp = (u == 0 || f <= u) ? 0 : (f - u) * 10_000 / u;
            bp1m[s] = bp;

            console2.log("block", blk);
            console2.log("   naturally-fresh venues", nat);
            console2.log("   Fermi depth at least  ", depth);
            console2.log("   Fermi edge @1M, bp    ", bp);
        }

        console2.log("");
        console2.log("=== SUMMARY over", samples);
        console2.log("blocks spanning", samples * step);
        console2.log("Fermi lane recoverable in", fermiOk);
        console2.log("at least ONE venue naturally fresh in", anyFresh);
        console2.log("TWO OR MORE naturally fresh in", multiFresh);
        console2.log("median Fermi depth", _median(depths));
        console2.log("median Fermi edge @1M, bp", _median(bp1m));
    }
}
