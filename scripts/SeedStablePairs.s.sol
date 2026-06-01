// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.35;

import "forge-std/Script.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";

/// @notice Seeds owner-curated Uniswap V3 fallback fee tiers for the deep mainnet
/// stablecoin pairs. Run by ROUTER_OWNER after deployment (setPairFees is onlyOwner).
/// @dev VERIFY the deepest live tier per pair before mainnet use — DAI/USDT 100 vs
/// 500 especially (its 0.05% pool has historically been deeper).
contract SeedStablePairs is Script {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @notice The pairs/tiers to seed. Edit here; both `run()` and the test use this.
    function seedData()
        public
        pure
        returns (address[] memory tokenA, address[] memory tokenB, uint24[] memory fees)
    {
        tokenA = new address[](3);
        tokenB = new address[](3);
        fees = new uint24[](3);

        // USDC/USDT — deepest at 0.01%.
        tokenA[0] = USDC; tokenB[0] = USDT; fees[0] = 100;
        // USDC/DAI — deepest at 0.01%.
        tokenA[1] = USDC; tokenB[1] = DAI; fees[1] = 100;
        // DAI/USDT — VERIFY 100 vs 500 against live liquidity before mainnet.
        tokenA[2] = DAI; tokenB[2] = USDT; fees[2] = 100;
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
