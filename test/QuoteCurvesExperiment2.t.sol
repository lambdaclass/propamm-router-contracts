// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

// ─────────────────────────────────────────────────────────────────────────
// THROWAWAY — Phase 0 experiment, part 2. The registry-priced venues (Fermi,
// Kipseli, Bebop, Tempest, TaurusFi) revert 0x666a2814 on a random fork block
// because their PrioUpdateRegistry lanes are only refreshed just-in-time with
// fills. Instead of replaying hardcoded price slots (stale prices), this rig
// discovers each venue's last REAL published lane timestamp by recording the
// registry storage reads its quote performs, warps to that moment, and sweeps
// the size ladder there — real prices, real inventory, fresh-enough lane.
// Run: RPC_URL=<mainnet rpc> forge test --match-contract QuoteCurvesExperiment2 -vv
// ─────────────────────────────────────────────────────────────────────────

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PRIO_UPDATE_REGISTRY} from "../test/interfaces/IPrioUpdateRegistry.sol";

contract QuoteCurvesExperiment2 is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant ROUTER = 0x4DdF368080CD7946db5b459aD591c350158175e1;
    uint256 constant USDC_BALANCES_SLOT = 9;

    IPropAMMRouter constant router = IPropAMMRouter(ROUTER);
    uint256 forkTs;

    function setUp() public {
        vm.createSelectFork(vm.envOr("RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        forkTs = block.timestamp;

        bytes32 slot = keccak256(abi.encode(ROUTER, USDC_BALANCES_SLOT));
        vm.store(USDC, slot, bytes32(uint256(50_000_000 * 1e6)));
        assertEq(IERC20(USDC).balanceOf(ROUTER), 50_000_000 * 1e6, "USDC fund failed");
        deal(WETH, ROUTER, 20_000 ether);
    }

    function _name(address v) internal pure returns (string memory) {
        if (v == 0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76) return "Bebop";
        if (v == 0x5979458912F80B96d30D4220af8E2e4925A33320) return "Fermi";
        if (v == 0x71e790dd841c8A9061487cb3E78C288E75cE0B3d) return "Kipseli";
        if (v == 0x00000003f1ec2379e79F58E12EC6C4F51Ee92149) return "Tempest";
        if (v == 0x217d58931A8549ca539426AA8152E33dAfc3d95A) return "TaurusFi";
        if (v == 0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB) return "Metric";
        return "unknown";
    }

    function test_quoteCurvesRestamped() public {
        console2.log(string.concat("BLOCK;", vm.toString(block.number), ";", vm.toString(forkTs)));

        address[5] memory staleVenues = [
            0x5979458912F80B96d30D4220af8E2e4925A33320, // Fermi
            0x71e790dd841c8A9061487cb3E78C288E75cE0B3d, // Kipseli
            0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76, // Bebop
            0x00000003f1ec2379e79F58E12EC6C4F51Ee92149, // Tempest
            0x217d58931A8549ca539426AA8152E33dAfc3d95A // TaurusFi
        ];

        uint256[14] memory usdcSizes = [
            uint256(100e6),
            500e6,
            1_000e6,
            5_000e6,
            10_000e6,
            25_000e6,
            50_000e6,
            100_000e6,
            250_000e6,
            500_000e6,
            1_000_000e6,
            2_500_000e6,
            5_000_000e6,
            10_000_000e6
        ];
        uint256[14] memory wethSizes = [
            uint256(0.05 ether),
            0.25 ether,
            0.5 ether,
            1 ether,
            2.5 ether,
            5 ether,
            10 ether,
            25 ether,
            50 ether,
            100 ether,
            250 ether,
            500 ether,
            1000 ether,
            2500 ether
        ];

        for (uint256 v = 0; v < staleVenues.length; v++) {
            address venue = staleVenues[v];
            uint256 freshTs = _findFreshTs(venue);
            if (freshTs == 0) {
                console2.log(string.concat("WARP;", _name(venue), ";none-found"));
                continue;
            }
            vm.warp(freshTs);
            console2.log(
                string.concat(
                    "WARP;",
                    _name(venue),
                    ";lane_ts=",
                    vm.toString(freshTs),
                    ";staleness_s=",
                    vm.toString(forkTs - freshTs)
                )
            );
            for (uint256 i = 0; i < usdcSizes.length; i++) {
                _quoteOne(venue, USDC, WETH, usdcSizes[i]);
            }
            for (uint256 i = 0; i < wethSizes.length; i++) {
                _quoteOne(venue, WETH, USDC, wethSizes[i]);
            }
            vm.warp(forkTs);
        }
    }

    /// @dev Records the registry storage slots a failing quote reads, then
    /// scans every byte-aligned 4-byte window of each read word for a value
    /// that parses as a recent-past unix timestamp; validates each candidate
    /// by warping to it and re-quoting. Returns 0 when nothing validates.
    function _findFreshTs(address venue) internal returns (uint256) {
        if (_tryQuote(venue)) return block.timestamp; // already fresh

        vm.record();
        _tryQuote(venue);
        (bytes32[] memory reads,) = vm.accesses(PRIO_UPDATE_REGISTRY);

        for (uint256 i = 0; i < reads.length; i++) {
            uint256 word = uint256(vm.load(PRIO_UPDATE_REGISTRY, reads[i]));
            if (word == 0) continue;
            // 4-byte windows at every byte offset: bit shifts 0, 8, ..., 224.
            for (uint256 shift = 0; shift <= 224; shift += 8) {
                uint32 cand = uint32(word >> shift);
                if (cand == 0 || cand > forkTs || cand < forkTs - 365 days) continue;
                vm.warp(cand);
                bool ok = _tryQuote(venue);
                vm.warp(forkTs);
                if (ok) return cand;
            }
        }
        return 0;
    }

    function _tryQuote(address venue) internal returns (bool) {
        try router.quoteVenueV1(venue, USDC, WETH, 100e6) returns (uint256 out, address) {
            return out > 0;
        } catch {
            return false;
        }
    }

    function _quoteOne(address venue, address tokenIn, address tokenOut, uint256 amountIn) internal {
        string memory tin = tokenIn == USDC ? "USDC" : "WETH";
        string memory tout = tokenOut == USDC ? "USDC" : "WETH";
        uint256 g0 = gasleft();
        try router.quoteVenueV1(venue, tokenIn, tokenOut, amountIn) returns (uint256 amountOut, address) {
            uint256 used = g0 - gasleft();
            console2.log(
                string.concat(
                    "CSV;",
                    _name(venue),
                    ";",
                    tin,
                    ";",
                    tout,
                    ";",
                    vm.toString(amountIn),
                    ";",
                    vm.toString(amountOut),
                    ";ok;",
                    vm.toString(used)
                )
            );
        } catch (bytes memory err) {
            uint256 used = g0 - gasleft();
            bytes memory sel = new bytes(err.length >= 4 ? 4 : err.length);
            for (uint256 i = 0; i < sel.length; i++) {
                sel[i] = err[i];
            }
            console2.log(
                string.concat(
                    "CSV;",
                    _name(venue),
                    ";",
                    tin,
                    ";",
                    tout,
                    ";",
                    vm.toString(amountIn),
                    ";0;revert:",
                    vm.toString(sel),
                    ";",
                    vm.toString(used)
                )
            );
        }
    }
}
