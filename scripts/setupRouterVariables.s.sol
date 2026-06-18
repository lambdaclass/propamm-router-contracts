// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {BEBOP_ROUTER} from "../src/interfaces/IBebopRouter.sol";

/// @notice Restores the fresh-deploy configuration on an already-deployed proxy:
/// the Uniswap V3 fallback fees (the global `fallbackFee` plus the owner-curated
/// per-pair tiers for the deep mainnet pairs — the stablecoin pair and the two
/// ETH/stable pairs) AND the default propAMM venue whitelist (Fermi, Kipseli,
/// Bebop). Run after an in-place proxy upgrade by the AccessManager role holders
/// that gate these selectors: `setFallbackFee`/`setPairFees` are `restricted` to
/// `UPGRADER_ROLE`, `addVenue` to `LISTING_ROLE`. NOTE: both roles carry an
/// execution delay, so against a configured manager these calls go through the
/// manager's schedule/execute flow (see `Upgrade.s.sol`/`Execute.s.sol`), not the
/// direct broadcast below — this script assumes a zero-delay (e.g. bootstrap-admin) context.
/// @dev A fresh deploy gets this exact config from `initialize`
/// (`fallbackFee = 3000` + `_seedDefaultPairFees` + the inline `_addVenue` calls), which is
/// initializer-gated and so never re-runs on upgrade; this script reproduces it for
/// upgraded proxies. Setting `fallbackFee` is required, not just the per-pair tiers:
/// a proxy that predates the per-pair fee map (an enum-era deployment) carries
/// `fallbackFee = 0`, which makes `resolvedFee` return the invalid tier `0` for every
/// UNSEEDED pair and revert the Uniswap fallback. Likewise such a proxy has an EMPTY
/// venue whitelist, so without re-adding the venues `swapV1` can only ever take the
/// Uniswap fallback and never route the propAMMs. The `addVenue` calls are guarded by
/// `isWhitelistedVenue` so the script stays idempotent and safe to re-run. Keep the
/// tiers and venue list in sync with the contract's `_seedDefaultPairFees` and the
/// inline `_addVenue` calls in `initialize` when either changes.
contract SetupRouterVariables is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Global fallback tier applied to any pair without a per-pair
    /// override. Matches `initialize`'s default (`3000` = 0.30%); the owner can
    /// retune it later via `setFallbackFee`.
    uint24 public constant FALLBACK_FEE = 3000;

    /// @notice The pairs/tiers to seed. Both `run()` and the test use this.
    function seedData() public pure returns (address[] memory tokenA, address[] memory tokenB, uint24[] memory fees) {
        tokenA = new address[](3);
        tokenB = new address[](3);
        fees = new uint24[](3);

        // USDC/USDT — stablecoin pair, deepest at 0.01%.
        tokenA[0] = USDC;
        tokenB[0] = USDT;
        fees[0] = 100;
        // USDC/WETH — ETH/stable, deepest at 0.05%.
        tokenA[1] = USDC;
        tokenB[1] = WETH;
        fees[1] = 500;
        // USDT/WETH — ETH/stable, deepest at 0.05%.
        tokenA[2] = USDT;
        tokenB[2] = WETH;
        fees[2] = 500;
    }

    /// @notice The default propAMM venues to whitelist — the same set `initialize`
    /// adds on a fresh deploy via its inline `_addVenue` calls. Both `run()` and
    /// the test use this.
    function venues() public pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = 0x5979458912F80B96d30D4220af8E2e4925A33320;
        list[1] = 0x71e790dd841c8A9061487cb3E78C288E75cE0B3d;
        list[2] = BEBOP_ROUTER;
    }

    function run() public {
        address payable proxy = payable(vm.envAddress("ROUTER_PROXY"));
        (address[] memory tokenA, address[] memory tokenB, uint24[] memory fees) = seedData();
        address[] memory venueList = venues();

        // The broadcaster MUST hold the AccessManager roles that gate these selectors
        // (UPGRADER_ROLE for setFallbackFee/setPairFees, LISTING_ROLE for addVenue).
        // Set the global fallback tier first so even pairs outside the
        // seeded set resolve to a valid tier, then apply the deep per-pair tiers, then
        // re-add the default propAMM venues. addVenue reverts on a duplicate, so guard
        // each with isWhitelistedVenue to keep the script idempotent / re-runnable.
        vm.startBroadcast();
        PropAMMRouter(proxy).setFallbackFee(FALLBACK_FEE);
        PropAMMRouter(proxy).setPairFees(tokenA, tokenB, fees);
        for (uint256 i = 0; i < venueList.length; i++) {
            if (!PropAMMRouter(proxy).isWhitelistedVenue(venueList[i])) {
                PropAMMRouter(proxy).addVenue(venueList[i]);
            }
        }
        vm.stopBroadcast();

        console.log("configured fallbackFee + pair tiers + venues on proxy:", proxy);
    }
}
