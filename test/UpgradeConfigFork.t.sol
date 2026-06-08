// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BlitzRouter} from "../src/BlitzRouter.sol";
import {SetupRouterVariables} from "../scripts/setupRouterVariables.s.sol";

/// @notice Mainnet-fork test of the real upgrade flow for the live proxy, which
/// was first deployed with the enum-era implementation (no `fallbackFee` storage).
/// Reproduces production exactly: a bare `upgradeToAndCall(newImpl, "")` (as
/// `scripts/Upgrade.s.sol` does), then the post-upgrade fee config applied the way
/// `scripts/setupRouterVariables.s.sol` does. Asserts the proxy is broken in between
/// and usable after.
/// @dev Forks via `ETH_RPC_URL`; the whole suite skips (not fails) when it is unset,
/// so CI without an archive/full node still passes.
contract UpgradeConfigForkTest is Test {
    address constant PROXY = 0x4DdF368080CD7946db5b459aD591c350158175e1;
    address constant OWNER = 0x82000112966349750f5abb770591E786DcCdEFf4;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    BlitzRouter router = BlitzRouter(payable(PROXY));
    SetupRouterVariables seed;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // no RPC -> tests self-skip
        vm.createSelectFork(rpc);
        seed = new SetupRouterVariables();
        forked = true;
    }

    /// @dev Bare upgrade with no reinitializer calldata, exactly like Upgrade.s.sol.
    function _bareUpgrade() internal {
        BlitzRouter newImpl = new BlitzRouter();
        vm.prank(OWNER);
        UUPSUpgradeable(PROXY).upgradeToAndCall(address(newImpl), "");
    }

    /// @dev Mirrors SetupRouterVariables.run(): set the global fallback fee, then the
    /// deep per-pair tiers, then re-add the default propAMM venues, broadcast by the
    /// owner.
    function _runConfigScript() internal {
        (address[] memory a, address[] memory b, uint24[] memory f) = seed.seedData();
        address[] memory venues = seed.venues();
        vm.startPrank(OWNER);
        router.setFallbackFee(seed.FALLBACK_FEE());
        router.setPairFees(a, b, f);
        for (uint256 i = 0; i < venues.length; i++) {
            if (!router.isWhitelistedVenue(venues[i])) {
                router.addVenue(venues[i]);
            }
        }
        vm.stopPrank();
    }

    /// The headline scenario: upgrade leaves fees zeroed (fallback dead), then the
    /// config script restores them and a real swap succeeds via the Uniswap fallback.
    function test_upgradeThenConfigScript_restoresFeesAndSwaps() public {
        if (!forked) {
            vm.skip(true);
            return;
        }

        _bareUpgrade();

        // Upgraded but not yet configured: fallbackFee is 0 and the Uniswap
        // fallback reverts (invalid tier 0) for any pair. The venue whitelist is
        // also empty — the venue seeding in `initialize` is initializer-gated
        // and never re-ran.
        assertEq(router.authority(), OWNER, "owner preserved across upgrade");
        assertEq(router.fallbackFee(), 0, "fallbackFee 0 right after bare upgrade");
        assertEq(router.whitelistedVenueCount(), 0, "no venues right after bare upgrade");
        vm.expectRevert();
        router.quoteUniswapV3(WETH, USDC, 1e18);

        _runConfigScript();

        // Fees restored to the fresh-deploy configuration.
        assertEq(router.fallbackFee(), 3000, "global fallback fee set");
        assertEq(router.resolvedFee(WETH, USDC), 500, "USDC/WETH seeded tier");
        assertEq(router.resolvedFee(USDT, USDC), 100, "USDC/USDT seeded tier");
        assertEq(router.resolvedFee(DAI, WETH), 3000, "unseeded pair -> global default");

        // Default propAMM venues restored too, so swapV1 can route them again.
        address[] memory venues = seed.venues();
        assertEq(router.whitelistedVenueCount(), venues.length, "all default venues whitelisted");
        for (uint256 i = 0; i < venues.length; i++) {
            assertTrue(router.isWhitelistedVenue(venues[i]), "venue whitelisted after config");
        }

        // A real swap now works. Bebop may quote highest but cannot fill on a fork
        // (no signed order), so _coreSwap falls through to the Uniswap fallback.
        address user = makeAddr("user");
        deal(WETH, user, 10 ether);
        vm.startPrank(user);
        IERC20(WETH).approve(PROXY, type(uint256).max);
        (uint256 out,) = router.swapV1(WETH, USDC, 1 ether, 0, user, block.timestamp + 1);
        vm.stopPrank();

        assertGt(out, 0, "swap delivered USDC");
        assertEq(IERC20(USDC).balanceOf(user), out, "recipient received exactly amountOut");
    }

    /// Justifies why the script sets `fallbackFee` and not just the per-pair tiers:
    /// seeding tiers alone leaves every UNSEEDED pair resolving to invalid tier 0.
    function test_seedingTiersAlone_leavesUnseededPairsBroken() public {
        if (!forked) {
            vm.skip(true);
            return;
        }

        _bareUpgrade();

        // Apply ONLY the per-pair tiers, skipping setFallbackFee.
        (address[] memory a, address[] memory b, uint24[] memory f) = seed.seedData();
        vm.prank(OWNER);
        router.setPairFees(a, b, f);

        // Seeded pair resolves fine...
        assertEq(router.resolvedFee(WETH, USDC), 500);
        // ...but fallbackFee is still 0, so an unseeded pair is unusable.
        assertEq(router.fallbackFee(), 0);
        assertEq(router.resolvedFee(DAI, WETH), 0);
        vm.expectRevert();
        router.quoteUniswapV3(DAI, WETH, 1e18);
    }
}
