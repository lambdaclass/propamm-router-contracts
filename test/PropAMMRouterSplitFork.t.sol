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
    uint256 constant PROBE_AMOUNT = 1_000e6; // small size, only used to test quotability
    uint256 constant ONE_YEAR = 365 days;

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
        vm.store(USDC, keccak256(abi.encode(taker, USDC_BALANCES_SLOT)), bytes32(SPLIT_AMOUNT));
        vm.prank(taker);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.deal(taker, 1 ether);
    }

    function test_split_fermiPlusUniswap_executes() public {
        bool fermiQuotable = _ensureFermiQuotable();

        (uint256 allUniQuote,) = router.quoteVenueV1(UNISWAP_ROUTER_02, USDC, WETH, SPLIT_AMOUNT);

        address[] memory venues = new address[](1);
        venues[0] = FERMI;
        uint256[] memory noHints = new uint256[](0);

        vm.prank(taker);
        uint256 amountOut = router.swapSplitV1(
            venues, noHints, USDC, WETH, SPLIT_AMOUNT, allUniQuote, 0, 8, taker, block.timestamp + 120
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
}
