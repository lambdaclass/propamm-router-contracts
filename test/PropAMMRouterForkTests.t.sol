// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PRIO_UPDATE_REGISTRY, IPrioUpdateRegistry} from "../test/interfaces/IPrioUpdateRegistry.sol";

/// @title PropAMMRouterForkTests
/// @notice Fork-test rig exercising the `IPropAMMRouter` interface against a
/// mainnet fork.
contract PropAMMRouterForkTests is Test {
    /// @dev Mainnet USDC (FiatTokenV2_2). Balance slot is 9 (packed with
    /// the high-bit blacklist flag); allowance slot is 10.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant USDC_ALLOWANCES_SLOT = 10;

    uint256 constant AMOUNT_IN = 100e6; // 100 USDC
    // The address of the mainnet PropAMMRouter contract (demo environment)
    address constant MAINNET_PROPAMM_ROUTER_ADDRESS = 0x4DdF368080CD7946db5b459aD591c350158175e1;

    /// @dev The Kipseli PAMM whitelisted by the live demo router — the same
    /// address `initialize` now seeds as the built-in Kipseli venue.
    address constant NEW_KIPSELI_PAMM = 0x71e790dd841c8A9061487cb3E78C288E75cE0B3d;
    address constant NEW_FERMI_ROUTER = 0x5979458912F80B96d30D4220af8E2e4925A33320;

    /// @dev Block of mainnet tx
    /// 0x7c3cb5e32867d724a51cbaede51c165454cbc59324511ff3470b983acaa705f0, a
    /// `swapViaVenueV1` USDC->WETH that settled through `NEW_KIPSELI_PAMM`.
    uint256 constant KIPSELI_FORK_BLOCK = 25_288_802;

    IPropAMMRouter router;
    address taker;

    function setUp() public {
        string memory rpc = vm.envString("RPC_URL");

        vm.createSelectFork(rpc);
        taker = makeAddr("taker");

        // Target the demo environment router
        router = IPropAMMRouter(MAINNET_PROPAMM_ROUTER_ADDRESS);

        _seedTaker();
    }

    /// @dev (Re)funds the taker with USDC, grants a max router allowance, and
    /// gives it ETH for gas. Idempotent so it can run again after a fork roll,
    /// which reloads account state from a different block and wipes these.
    function _seedTaker() internal {
        // Fund the taker with 1M USDC (well above the worst-case test spend).
        _fundTakerUSDC(1_000_000 * 1e6);
        _setMaxAllowance(USDC, taker, address(router));
        // Give the taker ETH for the tx-gas accounting that `vm.prank` will
        // hand to the EVM — Foundry's default would otherwise leave it at 0.
        vm.deal(taker, 10 ether);
    }

    /// @dev Calls the `swapViaVenueV1` function passing Kipseli as venue,
    /// and asserts the swap was actually executed by Kipseli (didn't fallback to Uniswap).
    /// It updates the price before sending the swap transaction.
    function test_swapViaVenueV1NewKipseli() public {
        // Skipped in CI: this test rolls the fork back to `KIPSELI_FORK_BLOCK`
        // and executes a swap, which requires the RPC to serve account state at
        // that historical block. CI uses the public node
        // `ethereum-rpc.publicnode.com`, which is not a full archive node and
        // returns "historical state ... is not available". Run locally against
        // an archive RPC (set `RPC_URL`) to exercise this lane.
        vm.skip(true);

        // Roll back to the block where `NEW_KIPSELI_PAMM` was whitelisted and
        // `swapViaVenueV1` settled through it on mainnet, then re-seed the taker
        // because the roll reloads account state from that block.
        vm.rollFork(KIPSELI_FORK_BLOCK);
        _seedTaker();
        _updateNewKipseliPrice();
        _runSwapViaVenueV1(NEW_KIPSELI_PAMM);
    }

    /// @dev Calls the `swapViaVenueV1` function passing Fermi as venue,
    /// and asserts the swap was actually executed by Fermi (didn't fallback to Uniswap).
    /// It updates the price before sending the swap transaction.
    function test_swapViaVenueV1Fermi() public {
        _updateFermiPrice();
        _runSwapViaVenueV1(NEW_FERMI_ROUTER);
    }

    /// @dev Calls the `swapViaVenueV1` function passing Uniswap (fallback) as venue.
    function test_swapViaVenueV1Fallback() public {
        _runSwapViaVenueV1(UNISWAP_ROUTER_02);
    }

    /// @dev Republishes the new Kipseli PAMM's pricing lane in the
    /// `PrioUpdateRegistry`, mirroring the mainnet updater transaction so the
    /// venue can quote and settle the swap. Authorizes this test contract as the
    /// lane's updater first (pranked as the lane target, which manages its own
    /// updater set), then writes the same target, lane, and price slots the real
    /// transaction used. The update timestamp is set to the current fork block
    /// time so it lands inside the registry's freshness window regardless of
    /// which block the fork pins to.
    function _updateNewKipseliPrice() internal {
        // Target, lane, and price slot all taken from the mainnet updater tx
        // 0xf7be932bf666b0fb4d10bbd0cd844876e24f0e75dfd11772907dff94e90513e8.
        // Pricing lane scoped to this target (the account that calls `getState`)
        // at lane 0.
        address priceTarget = 0xfE3d12b21d2602868223E83149bdBbFB5D11e185;
        uint256 laneIndex = 0;
        // Encoded price `slots[1]` (`slots[0]` is zero); replayed verbatim, the
        // timestamp is restamped to fork time in `_updateRegistryState`.
        uint256 priceSlot1 = 0x0000000000000000000000000000000000000000000000000054000e5bf95d7b;

        uint256[] memory slots = new uint256[](2);
        slots[0] = 0;
        slots[1] = priceSlot1;
        _updateRegistryState(priceTarget, laneIndex, slots);
    }

    /// @dev Republishes Fermi's pricing lane in the `PrioUpdateRegistry`,
    /// mirroring the mainnet updater transaction so the venue can quote and
    /// settle the swap. Same flow as `_updateNewKipseliPrice`: authorize this
    /// test contract as the lane's updater (pranked as the lane target), then
    /// write the target, lane, and single price slot the real transaction used.
    /// The update timestamp is set to the current fork block time so it lands
    /// inside the registry's freshness window regardless of the fork block.
    function _updateFermiPrice() internal {
        // Target, lane, and price slot all taken from the mainnet updater tx
        // 0x774c15474849b646ae2feab49379c7b178c1a32b4944e04aef842bb6823c6146
        // Fermi's pricing lane scoped to this target; unlike Kipseli's lane 0,
        // the lane index is a full 32-byte key.

        address priceTarget = 0x26e5A56f807d4C937B0b815266B135F09B4Bf312;
        uint256 laneIndex = 0x2eec03b8999af9793df60f1395a1b41c29e22b324ea3200ca21bc692979b9d46;
        // Single packed price slot; replayed verbatim, the timestamp is
        // restamped to fork time in `_updateRegistryState`.
        uint256 priceSlot0 = 0x0000000000000000000000000000000000000000000000000000002779853ea0;

        uint256[] memory slots = new uint256[](1);
        slots[0] = priceSlot0;
        _updateRegistryState(priceTarget, laneIndex, slots);
    }

    function _updateRegistryState(address target, uint256 laneIndex, uint256[] memory slots) internal {
        IPrioUpdateRegistry registry = IPrioUpdateRegistry(PRIO_UPDATE_REGISTRY);

        vm.prank(target);
        registry.addUpdater(address(this));

        registry.updateState(target, laneIndex, uint32(block.timestamp), slots);
    }

    function _fundTakerUSDC(uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(taker, USDC_BALANCES_SLOT));
        // USDC packs the blacklisted flag in the top bit. Writing a plain
        // uint256 with the high bit clear leaves the taker un-blacklisted and
        // sets the balance to `amount`.
        vm.store(USDC, slot, bytes32(amount));

        // Sanity-check via the public balanceOf to catch storage-layout
        // mistakes early.
        assertEq(IERC20(USDC).balanceOf(taker), amount, "USDC fund failed");
    }

    function _setMaxAllowance(address token, address owner, address spender) internal {
        bytes32 inner = keccak256(abi.encode(owner, USDC_ALLOWANCES_SLOT));
        bytes32 slot = keccak256(abi.encode(spender, inner));
        vm.store(token, slot, bytes32(type(uint256).max));

        assertEq(IERC20(token).allowance(owner, spender), type(uint256).max, "allowance set failed");
    }

    /// @dev Calls the `swapViaVenueV1` function, passing the given venue.
    /// It asserts the swap executed via the given venue, and `amountOut` is
    /// at least `amountOutMin`.
    function _runSwapViaVenueV1(address venue) internal {
        (uint256 amountOutMin,) = router.quoteVenueV1(venue, USDC, WETH, AMOUNT_IN);
        uint256 deadline = block.timestamp + 120;

        uint256 wethBalanceBeforeSwap = IERC20(WETH).balanceOf(taker);

        vm.prank(taker);
        (uint256 amountOut, address executedVenue) =
            router.swapViaVenueV1(venue, USDC, WETH, AMOUNT_IN, amountOutMin, taker, deadline);

        assertTrue(executedVenue == venue, "wrong execution venue for pinned swapViaVenueV1");
        assertGe(amountOut, amountOutMin, "amountOut < amountOutMin");
        assertEq(amountOut, IERC20(WETH).balanceOf(taker) - wethBalanceBeforeSwap, "amountOut != delta");
    }
}
