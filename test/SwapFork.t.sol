// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";

/// @title SwapForkTest
/// @notice Fork-test rig for `PropAMMRouter.swap(...)` gas measurement.
///
/// `setUp()` forks mainnet at the Titan-published block, deploys a fresh
/// PropAMMRouter (impl + UUPS proxy), funds the taker with USDC, and parses
/// three env-var-provided per-PMM storage-override arrays.
///
/// Each test applies one venue's overrides via `vm.store`, sends the swap
/// through the auto-venue entrypoint, and logs the gas delta. Because the
/// whole test runs in a single transaction context, `block.number` stays
/// at the Titan block — no per-tx drift like in the live-Anvil flow.
///
/// Driven by `contracts/scripts/run_fork_tests.sh`, which queries Titan,
/// flattens its nested override blob into `[{account, slot, value}, …]`
/// per venue, and exports the env vars before invoking `forge test`.
contract SwapForkTest is Test {
    /// @dev Mainnet USDC (FiatTokenV2_2). Balance slot is 9 (packed with
    /// the high-bit blacklist flag); allowance slot is 10.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev Uniswap V3 SwapRouter02 + QuoterV2 — same fallback wiring as
    /// `scripts/Deploy.s.sol`.
    address constant SWAP_ROUTER_02 =
        0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant USDC_ALLOWANCES_SLOT = 10;

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

        // Fund the taker with 1M USDC (well above the 12-scenario worst
        // case from the Mix-task days; the test only ever spends 100 USDC).
        _fundTakerUSDC(1_000_000 * 1e6);
        _setMaxAllowance(USDC, taker, address(router));
        // Give the taker ETH for the tx-gas accounting that `vm.prank` will
        // hand to the EVM — Foundry's default would otherwise leave it at 0.
        vm.deal(taker, 10 ether);
    }

    function test_swapViaFermi() public {
        // Defensive: pin block.number back to the Titan-published block
        // in case a sibling test (e.g. test_swapViaBebop) `vm.roll`ed
        // earlier and Foundry didn't fully revert it across the shared
        // fork.
        vm.roll(titanBlock);
        _applyAll(fermiStorage, fermiBalances, fermiNonces);
        _runSwap("fermi", IPropAMMRouter.Venue.FermiSwap);
    }

    function test_swapViaKipseli() public {
        vm.roll(titanBlock);
        _applyAll(kipseliStorage, kipseliBalances, kipseliNonces);
        _runSwap("kipseli", IPropAMMRouter.Venue.Kipseli);
    }

    function test_swapViaBebop() public {
        _applyAll(bebopStorage, bebopBalances, bebopNonces);
        // Bebop's freshness check (`block.number != mapping_3[idx]`) is
        // strict-equality. Titan's `result.blockNumber` can lead the
        // block stored in Bebop's mapping_3 by hundreds of blocks when
        // the maker hasn't pushed a fresh price recently. Roll to the
        // block at which Titan's Bebop override is internally
        // consistent — extracted in the bash wrapper from
        // mapping_3[0]'s value.
        uint256 bebopFresh = vm.envUint("BEBOP_FRESH_BLOCK");
        vm.roll(bebopFresh);
        _runSwap("bebop", IPropAMMRouter.Venue.Bebop);
    }

    function test_swapViaFallback() public {
        _runSwap("fallback", IPropAMMRouter.Venue.Fallback);
    }

    /// @dev All three propAMMs have a fresh Titan update applied. The
    /// router's quote loop should pick *some* proprietary venue (the one
    /// with the largest `amountOut`) — exactly which one varies with
    /// market state, so this test only asserts "not Fallback" rather
    /// than pinning a single venue. Block.number stays at `titanBlock`,
    /// so Bebop's mapping_3 freshness check may still fail; Fermi or
    /// Kipseli will win in that case.
    function test_swapViaAllPMMs() public {
        vm.roll(titanBlock);
        _applyAll(fermiStorage, fermiBalances, fermiNonces);
        _applyAll(kipseliStorage, kipseliBalances, kipseliNonces);
        _applyAll(bebopStorage, bebopBalances, bebopNonces);
        _runSwapExpectProprietary("all");
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
    /// (`vm.setNonceUnsafe`, which doesn't reject lower-than-current
    /// values the way `vm.setNonce` does).
    function _applyAll(
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
        // uint256 with the high bit clear leaves the taker un-blacklisted
        // and sets the balance to `amount`.
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

    function _runSwap(
        string memory label,
        IPropAMMRouter.Venue expectedVenue
    ) internal {
        uint256 amountIn = 100e6; // 100 USDC
        uint256 amountOutMin = 0;
        uint256 deadline = block.timestamp + 120;

        uint256 preWeth = IERC20(WETH).balanceOf(taker);

        emit log_named_uint("block.number", block.number);
        emit log_named_uint("titanBlock", titanBlock);
        vm.prank(taker);
        uint256 g0 = gasleft();
        (uint256 amountOut, IPropAMMRouter.Venue executedVenue) = router.swap(
            USDC,
            WETH,
            amountIn,
            amountOutMin,
            taker,
            3000,
            deadline
        );
        uint256 gasUsed = g0 - gasleft();

        emit log_named_uint(string.concat("gas:", label), gasUsed);
        emit log_named_uint(string.concat("amountOut:", label), amountOut);
        emit log_named_uint(
            string.concat("executedVenue:", label),
            uint256(uint8(executedVenue))
        );

        // The router tells us which venue actually settled the swap.
        // Accept either the expected PMM (the override we applied was the
        // best quote *and* the swap executed) or `Venue.Fallback` (Uniswap
        // V3 quoted higher than the PMM under test, or the PMM reverted at
        // execution and the catch arm engaged). Anything else is a real
        // routing bug.
        assertTrue(
            executedVenue == expectedVenue ||
                executedVenue == IPropAMMRouter.Venue.Fallback,
            string.concat("wrong execution venue for ", label)
        );

        // Confirm the recipient actually received WETH (i.e. we exercised
        // a real swap path, not just a failed-and-bubbled call).
        assertGt(
            IERC20(WETH).balanceOf(taker) - preWeth,
            0,
            "no WETH delivered"
        );
        assertEq(
            amountOut,
            IERC20(WETH).balanceOf(taker) - preWeth,
            "amountOut != delta"
        );
    }

    /// @dev Like `_runSwap` but only asserts the auto-router picked
    /// *some* proprietary venue (i.e. NOT `Venue.Fallback`). Useful when
    /// every PMM has fresh data and the specific winner is
    /// market-state-dependent.
    function _runSwapExpectProprietary(string memory label) internal {
        uint256 amountIn = 100e6;
        uint256 amountOutMin = 0;
        uint256 deadline = block.timestamp + 120;

        uint256 preWeth = IERC20(WETH).balanceOf(taker);

        emit log_named_uint("block.number", block.number);
        emit log_named_uint("titanBlock", titanBlock);
        vm.prank(taker);
        uint256 g0 = gasleft();
        (uint256 amountOut, IPropAMMRouter.Venue executedVenue) = router.swap(
            USDC,
            WETH,
            amountIn,
            amountOutMin,
            taker,
            3000,
            deadline
        );
        uint256 gasUsed = g0 - gasleft();

        emit log_named_uint(string.concat("gas:", label), gasUsed);
        emit log_named_uint(string.concat("amountOut:", label), amountOut);
        emit log_named_uint(
            string.concat("executedVenue:", label),
            uint256(uint8(executedVenue))
        );

        assertTrue(
            executedVenue != IPropAMMRouter.Venue.Fallback,
            string.concat(
                "expected proprietary venue but got Fallback for ",
                label
            )
        );

        assertGt(
            IERC20(WETH).balanceOf(taker) - preWeth,
            0,
            "no WETH delivered"
        );
        assertEq(
            amountOut,
            IERC20(WETH).balanceOf(taker) - preWeth,
            "amountOut != delta"
        );
    }
}
