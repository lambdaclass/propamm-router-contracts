// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";

/// @notice Configures the Uniswap V3 fallback fees on an already-deployed proxy:
/// the global `fallbackFee` plus the owner-curated per-pair tiers for the deep
/// mainnet pairs (the stablecoin pair and the two ETH/stable pairs). Run by
/// ROUTER_OWNER after an in-place proxy upgrade (`setFallbackFee`/`setPairFees`
/// are onlyOwner).
/// @dev A fresh deploy gets this exact config from `initialize`
/// (`fallbackFee = 3000` + `_seedDefaultPairFees`), which is initializer-gated and
/// so never re-runs on upgrade; this script reproduces it for upgraded proxies.
/// Setting `fallbackFee` is required, not just the per-pair tiers: a proxy that
/// predates the per-pair fee map (an enum-era deployment) carries `fallbackFee = 0`,
/// which makes `_resolveFee` return the invalid tier `0` for every UNSEEDED pair
/// and revert the Uniswap fallback. Keep the tiers in sync with the contract's
/// `_seedDefaultPairFees` when either changes.
contract SeedStablePairs is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Global fallback tier applied to any pair without a per-pair
    /// override. Matches `initialize`'s default (`3000` = 0.30%); the owner can
    /// retune it later via `setFallbackFee`.
    uint24 public constant FALLBACK_FEE = 3000;

    /// @notice The pairs/tiers to seed. Edit here; both `run()` and the test use this.
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

    function run() public {
        address proxy = vm.envAddress("ROUTER_PROXY");
        (address[] memory tokenA, address[] memory tokenB, uint24[] memory fees) = seedData();

        // The broadcaster MUST be ROUTER_OWNER — setFallbackFee/setPairFees are
        // onlyOwner. Set the global fallback tier first so even pairs outside the
        // seeded set resolve to a valid tier, then apply the deep per-pair tiers.
        vm.startBroadcast();
        PropAMMRouter(proxy).setFallbackFee(FALLBACK_FEE);
        PropAMMRouter(proxy).setPairFees(tokenA, tokenB, fees);
        vm.stopBroadcast();

        console.log("configured fallbackFee + pair tiers on proxy:", proxy);
    }
}
