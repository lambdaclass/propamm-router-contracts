// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {FERMI_ROUTER} from "../src/interfaces/IFermiSwapper.sol";
import {BEBOP_ROUTER} from "../src/interfaces/IBebopRouter.sol";
import {KIPSELI_PAMM} from "../src/interfaces/IKipseliPAMM.sol";

/// @title PropAMMRouterForkTests
/// @notice Fork-test rig exercising the `IPropAMMRouter` interface against a
/// mainnet fork: the swap entrypoints (`swapV1`, `swapViaVenueV1`,
/// `swapViaSelectedVenuesV1`) and the quote views (`quoteV1`, `quoteVenueV1`,
/// `quoteSelectedVenuesV1`).
///
/// `setUp()` forks mainnet at the Titan-published block, deploys a fresh
/// PropAMMRouter (impl + UUPS proxy), funds the taker with USDC, and parses
/// three env-var-provided per-PMM storage-override arrays.
///
/// Each test applies one venue's overrides via `vm.store`, sends the swap
/// through the chosen entrypoint, and logs the gas delta. Because the whole
/// test runs in a single transaction context, `block.number` stays at the
/// Titan block — no per-tx drift like in the live-Anvil flow.
///
/// Venues are identified by router address. The public-venue fallback is the
/// `fallbackSwapRouter` (Uniswap V3 SwapRouter02); it is a nameable venue
/// (`quoteVenueV1` / `swapViaVenueV1` accept it) and is also the automatic
/// safety net. So a swap's `executedVenue` is either the proprietary venue
/// under test or `SWAP_ROUTER_02`.
///
/// Driven by `scripts/run_fork_tests.sh`, which queries Titan, flattens its
/// nested override blob into `[{account, slot, value}, …]` per venue, and
/// exports the env vars before invoking `forge test`.
contract PropAMMRouterForkTests is Test {
    /// @dev Mainnet USDC (FiatTokenV2_2). Balance slot is 9 (packed with
    /// the high-bit blacklist flag); allowance slot is 10.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev Uniswap V3 SwapRouter02 + QuoterV2 — same fallback wiring as
    /// `scripts/Deploy.s.sol`. `SWAP_ROUTER_02` doubles as the venue address
    /// the router reports (and that callers may name) for the public-venue
    /// fallback.
    address constant SWAP_ROUTER_02 =
        0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant USDC_ALLOWANCES_SLOT = 10;

    uint256 constant AMOUNT_IN = 100e6; // 100 USDC

    /// @dev Flat shapes the bash wrapper emits per venue. Field names are
    /// alphabetical, matching Foundry's `parseJson` decoding order.
    struct StorageOverride {
        address account;
        bytes32 slot;
        bytes32 value;
    }

    /// @dev Same shape used for `balance` and `nonce` overrides — both
    /// are per-account scalars (no slot key needed).
    struct AccountValue {
        address account;
        bytes32 value;
    }

    PropAMMRouter router;
    address taker;

    StorageOverride[] fermiStorage;
    AccountValue[] fermiBalances;
    AccountValue[] fermiNonces;

    StorageOverride[] kipseliStorage;
    AccountValue[] kipseliBalances;
    AccountValue[] kipseliNonces;

    StorageOverride[] bebopStorage;
    AccountValue[] bebopBalances;
    AccountValue[] bebopNonces;

    uint256 titanBlock;

    function setUp() public {
        string memory rpc = vm.envString("ETH_RPC_URL");
        titanBlock = vm.envUint("TITAN_BLOCK");

        vm.createSelectFork(rpc, titanBlock);

        _stashStorage(fermiStorage, vm.envString("TITAN_FERMI_STORAGE"));
        _stashAccounts(fermiBalances, vm.envString("TITAN_FERMI_BALANCES"));
        _stashAccounts(fermiNonces, vm.envString("TITAN_FERMI_NONCES"));

        _stashStorage(kipseliStorage, vm.envString("TITAN_KIPSELI_STORAGE"));
        _stashAccounts(kipseliBalances, vm.envString("TITAN_KIPSELI_BALANCES"));
        _stashAccounts(kipseliNonces, vm.envString("TITAN_KIPSELI_NONCES"));

        _stashStorage(bebopStorage, vm.envString("TITAN_BEBOP_STORAGE"));
        _stashAccounts(bebopBalances, vm.envString("TITAN_BEBOP_BALANCES"));
        _stashAccounts(bebopNonces, vm.envString("TITAN_BEBOP_NONCES"));

        taker = makeAddr("taker");

        PropAMMRouter impl = new PropAMMRouter();
        bytes memory init = abi.encodeCall(
            PropAMMRouter.initialize,
            (SWAP_ROUTER_02, QUOTER_V2, address(this))
        );
        router = PropAMMRouter(
            payable(address(new ERC1967Proxy(address(impl), init)))
        );

        // Fund the taker with 1M USDC (well above the worst-case test spend).
        _fundTakerUSDC(1_000_000 * 1e6);
        _setMaxAllowance(USDC, taker, address(router));
        // Give the taker ETH for the tx-gas accounting that `vm.prank` will
        // hand to the EVM — Foundry's default would otherwise leave it at 0.
        vm.deal(taker, 10 ether);
    }

    // -------------------------------------------------------------
    // swapV1 — auto-selects the best venue across PMMs + fallback
    // -------------------------------------------------------------

    function test_swapV1ViaFermi() public {
        // Defensive: pin block.number back to the Titan-published block
        // in case a sibling test (e.g. test_swapV1ViaBebop) `vm.roll`ed
        // earlier and Foundry didn't fully revert it across the shared fork.
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        _runSwapV1("fermi", FERMI_ROUTER);
    }

    function test_swapV1ViaKipseli() public {
        vm.roll(titanBlock);
        _overrideState(kipseliStorage, kipseliBalances, kipseliNonces);
        _runSwapV1("kipseli", KIPSELI_PAMM);
    }

    function test_swapV1ViaBebop() public {
        _overrideState(bebopStorage, bebopBalances, bebopNonces);
        // Bebop only accepts a swap at the exact block its latest price was
        // published for, which may trail Titan's reported block. Roll to that
        // block so the override is accepted.
        uint256 bebopFresh = vm.envUint("BEBOP_FRESH_BLOCK");
        vm.roll(bebopFresh);
        _runSwapV1("bebop", BEBOP_ROUTER);
    }

    function test_swapV1ViaFallback() public {
        // No PMM overrides applied, so the public-venue fallback wins.
        _runSwapV1("fallback", SWAP_ROUTER_02);
    }

    // -------------------------------------------------------------
    // swapViaVenueV1 — caller pins a single venue
    // -------------------------------------------------------------

    function test_swapViaVenueV1Fermi() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        _runSwapViaVenueV1(FERMI_ROUTER);
    }

    function test_swapViaVenueV1Kipseli() public {
        vm.roll(titanBlock);
        _overrideState(kipseliStorage, kipseliBalances, kipseliNonces);
        _runSwapViaVenueV1(KIPSELI_PAMM);
    }

    function test_swapViaVenueV1Bebop() public {
        _overrideState(bebopStorage, bebopBalances, bebopNonces);
        uint256 bebopFresh = vm.envUint("BEBOP_FRESH_BLOCK");
        vm.roll(bebopFresh);
        _runSwapViaVenueV1(BEBOP_ROUTER);
    }

    /// @dev Naming the fallback address routes directly to the public venue.
    function test_swapViaVenueV1Fallback() public {
        _runSwapViaVenueV1(SWAP_ROUTER_02);
    }

    /// @dev A non-whitelisted, non-fallback address must revert `UnknownVenue`
    /// before any funds move.
    function test_swapViaVenueV1RevertsForUnknownVenue() public {
        uint256 deadline = block.timestamp + 120;
        vm.prank(taker);
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.swapViaVenueV1(
            makeAddr("not-a-venue"),
            USDC,
            WETH,
            AMOUNT_IN,
            0,
            taker,
            deadline
        );
    }

    // -------------------------------------------------------------
    // swapViaSelectedVenuesV1 — best of a caller-supplied venue subset
    // -------------------------------------------------------------

    function test_swapViaSelectedVenuesV1Fermi() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        _runSwapViaSelectedVenuesV1("fermi", _venues(FERMI_ROUTER));
    }

    function test_swapViaSelectedVenuesV1Kipseli() public {
        vm.roll(titanBlock);
        _overrideState(kipseliStorage, kipseliBalances, kipseliNonces);
        _runSwapViaSelectedVenuesV1("kipseli", _venues(KIPSELI_PAMM));
    }

    function test_swapViaSelectedVenuesV1Bebop() public {
        _overrideState(bebopStorage, bebopBalances, bebopNonces);
        uint256 bebopFresh = vm.envUint("BEBOP_FRESH_BLOCK");
        vm.roll(bebopFresh);
        _runSwapViaSelectedVenuesV1("bebop", _venues(BEBOP_ROUTER));
    }

    /// @dev With only Fermi's override applied, passing the full PMM set must
    /// still pick Fermi: the un-overridden Kipseli/Bebop quotes revert and are
    /// skipped, so Fermi wins the subset selection.
    function test_swapViaSelectedVenuesV1PicksBestAmongSubset() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        address[] memory venues = new address[](3);
        venues[0] = FERMI_ROUTER;
        venues[1] = KIPSELI_PAMM;
        venues[2] = BEBOP_ROUTER;

        (, address quotedVenue) = router.quoteSelectedVenuesV1(
            venues,
            USDC,
            WETH,
            AMOUNT_IN
        );
        assertEq(quotedVenue, FERMI_ROUTER, "expected Fermi to win the subset");
        _runSwapViaSelectedVenuesV1("subset", venues);
    }

    // -------------------------------------------------------------
    // Deadline enforcement — every swap entrypoint reverts `Expired`
    // once `block.timestamp > deadline`, before pulling any funds.
    // -------------------------------------------------------------

    function test_swapV1RevertsAfterDeadline() public {
        uint256 pastDeadline = block.timestamp - 1;
        vm.prank(taker);
        vm.expectRevert(PropAMMRouter.Expired.selector);
        router.swapV1(USDC, WETH, AMOUNT_IN, 0, taker, pastDeadline);
    }

    function test_swapViaVenueV1RevertsAfterDeadline() public {
        // Pass a valid venue so the deadline check (in `_coreSwap`) is the
        // reason for the revert, not `UnknownVenue`.
        uint256 pastDeadline = block.timestamp - 1;
        vm.prank(taker);
        vm.expectRevert(PropAMMRouter.Expired.selector);
        router.swapViaVenueV1(
            FERMI_ROUTER,
            USDC,
            WETH,
            AMOUNT_IN,
            0,
            taker,
            pastDeadline
        );
    }

    function test_swapViaSelectedVenuesV1RevertsAfterDeadline() public {
        uint256 pastDeadline = block.timestamp - 1;
        vm.prank(taker);
        vm.expectRevert(PropAMMRouter.Expired.selector);
        router.swapViaSelectedVenuesV1(
            _venues(FERMI_ROUTER),
            USDC,
            WETH,
            AMOUNT_IN,
            0,
            taker,
            pastDeadline
        );
    }

    // -------------------------------------------------------------
    // quoteV1 — best quote across all venues
    // -------------------------------------------------------------

    function test_quoteV1() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);

        (uint256 bestQuote, address venue) = router.quoteV1(
            USDC,
            WETH,
            AMOUNT_IN
        );

        assertGt(bestQuote, 0, "quoteV1 returned zero");
        assertTrue(_isKnownVenue(venue), "quoteV1 returned an unknown venue");
        // The reported best must match that venue's own single-venue quote.
        assertEq(
            bestQuote,
            router.quoteVenueV1(venue, USDC, WETH, AMOUNT_IN),
            "quoteV1 best != quoteVenueV1(best venue)"
        );
    }

    // -------------------------------------------------------------
    // quoteVenueV1 — single venue by address
    // -------------------------------------------------------------

    function test_quoteVenueV1Fermi() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        assertGt(
            router.quoteVenueV1(FERMI_ROUTER, USDC, WETH, AMOUNT_IN),
            0,
            "fermi quote is zero"
        );
    }

    /// @dev The fallback (Uniswap) is a nameable venue and reads live on-chain
    /// pool state, so it needs no Titan override.
    function test_quoteVenueV1Fallback() public {
        assertGt(
            router.quoteVenueV1(SWAP_ROUTER_02, USDC, WETH, AMOUNT_IN),
            0,
            "fallback quote is zero"
        );
    }

    function test_quoteVenueV1RevertsForUnknownVenue() public {
        vm.expectRevert(PropAMMRouter.UnknownVenue.selector);
        router.quoteVenueV1(makeAddr("not-a-venue"), USDC, WETH, AMOUNT_IN);
    }

    // -------------------------------------------------------------
    // quoteSelectedVenuesV1 — best quote across a caller-supplied subset
    // -------------------------------------------------------------

    function test_quoteSelectedVenuesV1Fermi() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        _assertSelectedQuoteSingle(FERMI_ROUTER);
    }

    function test_quoteSelectedVenuesV1Kipseli() public {
        vm.roll(titanBlock);
        _overrideState(kipseliStorage, kipseliBalances, kipseliNonces);
        _assertSelectedQuoteSingle(KIPSELI_PAMM);
    }

    function test_quoteSelectedVenuesV1Bebop() public {
        _overrideState(bebopStorage, bebopBalances, bebopNonces);
        uint256 bebopFresh = vm.envUint("BEBOP_FRESH_BLOCK");
        vm.roll(bebopFresh);
        _assertSelectedQuoteSingle(BEBOP_ROUTER);
    }

    /// @dev An empty `venues` array yields no positive quote and must revert
    /// `NoQuotesAvailable`.
    function test_quoteSelectedVenuesV1EmptyReverts() public {
        address[] memory venues = new address[](0);
        vm.expectRevert(PropAMMRouter.NoQuotesAvailable.selector);
        router.quoteSelectedVenuesV1(venues, USDC, WETH, AMOUNT_IN);
    }

    /// @dev A non-whitelisted address in the subset is skipped (its
    /// `quoteVenueV1` reverts `UnknownVenue`, caught by the loop), so the
    /// remaining valid venue still wins.
    function test_quoteSelectedVenuesV1SkipsUnknownAddress() public {
        vm.roll(titanBlock);
        _overrideState(fermiStorage, fermiBalances, fermiNonces);
        address[] memory venues = new address[](2);
        venues[0] = makeAddr("not-a-venue");
        venues[1] = FERMI_ROUTER;

        (uint256 amountOut, address venue) = router.quoteSelectedVenuesV1(
            venues,
            USDC,
            WETH,
            AMOUNT_IN
        );
        assertEq(venue, FERMI_ROUTER, "unknown address should be skipped");
        assertGt(amountOut, 0, "no quote returned");
    }

    // -------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------

    /// @dev Parses the flat `[{account, slot, value}, …]` env JSON and pushes
    /// each row into the storage array. Storage arrays can't be assigned
    /// wholesale so we copy element by element.
    function _stashStorage(
        StorageOverride[] storage dst,
        string memory json
    ) internal {
        bytes memory raw = vm.parseJson(json);
        StorageOverride[] memory list = abi.decode(raw, (StorageOverride[]));
        for (uint256 i = 0; i < list.length; i++) {
            dst.push(list[i]);
        }
    }

    /// @dev Same idea for the `{account, value}` shape used by balance and
    /// nonce overrides.
    function _stashAccounts(
        AccountValue[] storage dst,
        string memory json
    ) internal {
        bytes memory raw = vm.parseJson(json);
        AccountValue[] memory list = abi.decode(raw, (AccountValue[]));
        for (uint256 i = 0; i < list.length; i++) {
            dst.push(list[i]);
        }
    }

    /// @dev Apply one venue's full override package: storage slots
    /// (`vm.store`), per-account balances (`vm.deal`), per-account nonces
    /// (`vm.setNonceUnsafe`, which doesn't reject lower-than-current values the
    /// way `vm.setNonce` does).
    function _overrideState(
        StorageOverride[] storage storageList,
        AccountValue[] storage balanceList,
        AccountValue[] storage nonceList
    ) internal {
        for (uint256 i = 0; i < storageList.length; i++) {
            vm.store(
                storageList[i].account,
                storageList[i].slot,
                storageList[i].value
            );
        }
        for (uint256 i = 0; i < balanceList.length; i++) {
            vm.deal(balanceList[i].account, uint256(balanceList[i].value));
        }
        for (uint256 i = 0; i < nonceList.length; i++) {
            vm.setNonceUnsafe(
                nonceList[i].account,
                uint64(uint256(nonceList[i].value))
            );
        }
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

    function _setMaxAllowance(
        address token,
        address owner,
        address spender
    ) internal {
        bytes32 inner = keccak256(abi.encode(owner, USDC_ALLOWANCES_SLOT));
        bytes32 slot = keccak256(abi.encode(spender, inner));
        vm.store(token, slot, bytes32(type(uint256).max));

        assertEq(
            IERC20(token).allowance(owner, spender),
            type(uint256).max,
            "allowance set failed"
        );
    }

    /// @dev Builds a single-element venue array.
    function _venues(address venue) internal pure returns (address[] memory) {
        address[] memory venues = new address[](1);
        venues[0] = venue;
        return venues;
    }

    /// @dev True for any address a caller may name as a venue: the three
    /// proprietary AMMs or the public-venue fallback.
    function _isKnownVenue(address venue) internal pure returns (bool) {
        return
            venue == FERMI_ROUTER ||
            venue == KIPSELI_PAMM ||
            venue == BEBOP_ROUTER ||
            venue == SWAP_ROUTER_02;
    }

    function _runSwapV1(string memory label, address expectedVenue) internal {
        // `quoteVenueV1` prices every nameable venue, including the fallback.
        uint256 amountOutMin = router.quoteVenueV1(
            expectedVenue,
            USDC,
            WETH,
            AMOUNT_IN
        );
        uint256 deadline = block.timestamp + 120;

        uint256 wethBalanceBeforeSwap = IERC20(WETH).balanceOf(taker);

        vm.prank(taker);
        (uint256 amountOut, address executedVenue) = router.swapV1(
            USDC,
            WETH,
            AMOUNT_IN,
            amountOutMin,
            taker,
            deadline
        );

        // The router tells us which venue actually settled the swap. Accept
        // either the expected venue (its quote was best and it executed) or the
        // fallback (`SWAP_ROUTER_02` quoted higher, or the PMM reverted at
        // execution and the fallback engaged). Anything else is a routing bug.
        assertTrue(
            executedVenue == expectedVenue || executedVenue == SWAP_ROUTER_02,
            string.concat("wrong execution venue for ", label)
        );

        _assertReceived(amountOut, amountOutMin, wethBalanceBeforeSwap);
    }

    /// @dev `swapViaVenueV1` counterpart of `_runSwapV1`. The caller pins the
    /// venue, so there's no `executedVenue` return value to assert on — just
    /// check the recipient received WETH and the returned `amountOut` matches
    /// the balance delta.
    function _runSwapViaVenueV1(address venue) internal {
        uint256 amountOutMin = router.quoteVenueV1(venue, USDC, WETH, AMOUNT_IN);
        uint256 deadline = block.timestamp + 120;

        uint256 wethBalanceBeforeSwap = IERC20(WETH).balanceOf(taker);

        vm.prank(taker);
        uint256 amountOut = router.swapViaVenueV1(
            venue,
            USDC,
            WETH,
            AMOUNT_IN,
            amountOutMin,
            taker,
            deadline
        );

        _assertReceived(amountOut, amountOutMin, wethBalanceBeforeSwap);
    }

    /// @dev `swapViaSelectedVenuesV1` counterpart. Requotes the subset via
    /// `quoteSelectedVenuesV1` to derive `amountOutMin` (and the venue the
    /// router will pick), then swaps and asserts the executed venue is that pick
    /// or the fallback.
    function _runSwapViaSelectedVenuesV1(
        string memory label,
        address[] memory venues
    ) internal {
        (uint256 amountOutMin, address quotedVenue) = router
            .quoteSelectedVenuesV1(venues, USDC, WETH, AMOUNT_IN);
        uint256 deadline = block.timestamp + 120;

        uint256 wethBalanceBeforeSwap = IERC20(WETH).balanceOf(taker);

        vm.prank(taker);
        (uint256 amountOut, address executedVenue) = router
            .swapViaSelectedVenuesV1(
                venues,
                USDC,
                WETH,
                AMOUNT_IN,
                amountOutMin,
                taker,
                deadline
            );

        // Either the requoted winner executed, or it reverted and the fallback
        // engaged.
        assertTrue(
            executedVenue == quotedVenue || executedVenue == SWAP_ROUTER_02,
            string.concat("wrong execution venue for ", label)
        );

        _assertReceived(amountOut, amountOutMin, wethBalanceBeforeSwap);
    }

    /// @dev Asserts `quoteSelectedVenuesV1` over the single `venue` returns that
    /// venue and a positive amount equal to the direct `quoteVenueV1` reading.
    function _assertSelectedQuoteSingle(address venue) internal {
        uint256 direct = router.quoteVenueV1(venue, USDC, WETH, AMOUNT_IN);
        (uint256 amountOut, address picked) = router.quoteSelectedVenuesV1(
            _venues(venue),
            USDC,
            WETH,
            AMOUNT_IN
        );

        assertEq(picked, venue, "quoteSelectedVenuesV1 returned wrong venue");
        assertGt(amountOut, 0, "quoteSelectedVenuesV1 returned zero");
        assertEq(
            amountOut,
            direct,
            "quoteSelectedVenuesV1 != quoteVenueV1"
        );
    }

    /// @dev Shared post-swap assertions: output meets the floor and equals the
    /// recipient's measured WETH balance delta.
    function _assertReceived(
        uint256 amountOut,
        uint256 amountOutMin,
        uint256 wethBalanceBeforeSwap
    ) internal view {
        assertGe(amountOut, amountOutMin, "amountOut < amountOutMin");
        assertEq(
            amountOut,
            IERC20(WETH).balanceOf(taker) - wethBalanceBeforeSwap,
            "amountOut != delta"
        );
    }
}
