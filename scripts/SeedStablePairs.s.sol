// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";

/// @notice Seeds the owner-curated Uniswap V3 fallback fee tiers for the deep
/// mainnet pairs: the stablecoin pair plus the two ETH/stable pairs. Run by
/// ROUTER_OWNER after deployment (setPairFees is onlyOwner).
/// @dev Mirrors the contract's `_seedDefaultPairFees` (run in `initialize`), so an
/// in-place proxy upgrade — which never re-runs `initialize` — ends up with the
/// same tier map as a from-scratch deploy. Keep the two in sync when either changes.
contract SeedStablePairs is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

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

        // The broadcaster MUST be ROUTER_OWNER — setPairFees is onlyOwner.
        vm.startBroadcast();
        PropAMMRouter(proxy).setPairFees(tokenA, tokenB, fees);
        vm.stopBroadcast();

        console.log("seeded pair fees on proxy:", proxy);
    }
}
