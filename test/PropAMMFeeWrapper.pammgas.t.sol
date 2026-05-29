// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {PropAMMFeeWrapper} from "../src/PropAMMFeeWrapper.sol";
import {PropAMMRouterWithFee} from "../src/PropAMMRouterWithFee.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";

/// @notice Wrapper-overhead measurement on the GENUINE proprietary-AMM path.
///
/// Reuses the Titan-override rig from PR #39 (`SwapFork.t.sol` /
/// `run_fork_tests.sh`): fork at the Titan-published block, apply each venue's
/// `stateOverride` via `vm.store` / `vm.deal` / `vm.setNonceUnsafe` so the
/// propAMM actually FILLS instead of reverting into the Uniswap V3 fallback,
/// then measure `router.swap(Venue.X)` DIRECT vs through `PropAMMFeeWrapper`.
///
/// Per venue, three swaps are measured from one snapshot (so they share an
/// identical starting state):
///   1. a Uniswap V3 Fallback reference (to detect whether the venue truly
///      filled — `out != fallbackOut` ⇒ filled via the propAMM),
///   2. the direct router swap through the venue,
///   3. the same swap through the fee wrapper.
///
/// Swap is USDC->WETH, 100 USDC, mirroring PR #39 so the Titan overrides apply.
///
/// Driven by scripts/run_wrapper_pamm_gas.sh, which queries Titan and exports
/// the TITAN_* env vars. Self-skips when they're absent.
contract PropAMMFeeWrapperPammForkGasTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant SWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant USDC_ALLOWANCES_SLOT = 10;

    uint256 constant AMOUNT_IN = 100e6; // 100 USDC
    uint16 constant FEE_BPS = 50; // 0.5%
    uint24 constant UNI_FEE = 500; // USDC/WETH 0.05% (fallback reference tier)

    // Alphabetical fields so Foundry's parseJson struct decoding lines up.
    struct StorageOverride {
        address account;
        bytes32 slot;
        bytes32 value;
    }

    struct AccountValue {
        address account;
        bytes32 value;
    }

    PropAMMRouter router;
    PropAMMFeeWrapper wrapper;
    PropAMMRouterWithFee routerWithFee;
    address taker;
    address feeRecipient = makeAddr("feeRecipient");

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
    bool ready;

    function setUp() public {
        try vm.envUint("TITAN_BLOCK") returns (uint256 tb) {
            titanBlock = tb;
            vm.createSelectFork(vm.envString("ETH_RPC_URL"), titanBlock);

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
            router = PropAMMRouter(payable(address(new ERC1967Proxy(
                address(impl),
                abi.encodeCall(PropAMMRouter.initialize, (SWAP_ROUTER_02, QUOTER_V2, address(this)))
            ))));

            PropAMMFeeWrapper wimpl = new PropAMMFeeWrapper();
            wrapper = PropAMMFeeWrapper(address(new ERC1967Proxy(
                address(wimpl),
                abi.encodeCall(PropAMMFeeWrapper.initialize, (address(router), feeRecipient, FEE_BPS, address(this)))
            )));

            PropAMMRouterWithFee rwfImpl = new PropAMMRouterWithFee();
            routerWithFee = PropAMMRouterWithFee(payable(address(new ERC1967Proxy(
                address(rwfImpl),
                abi.encodeWithSignature(
                    "initialize(address,address,address,address,uint16)",
                    SWAP_ROUTER_02, QUOTER_V2, address(this), feeRecipient, FEE_BPS
                )
            ))));

            _fundTakerUSDC(1_000_000e6);
            _setMaxAllowance(USDC, taker, address(router));
            _setMaxAllowance(USDC, taker, address(wrapper));
            _setMaxAllowance(USDC, taker, address(routerWithFee));
            vm.deal(taker, 10 ether);
            ready = true;
        } catch {
            ready = false;
        }
    }

    // ---- override plumbing (vendored from PR #39 SwapFork.t.sol) ----

    function _stashStorage(StorageOverride[] storage dst, string memory json) internal {
        bytes memory raw = vm.parseJson(json);
        StorageOverride[] memory list = abi.decode(raw, (StorageOverride[]));
        for (uint256 i = 0; i < list.length; i++) dst.push(list[i]);
    }

    function _stashAccounts(AccountValue[] storage dst, string memory json) internal {
        bytes memory raw = vm.parseJson(json);
        AccountValue[] memory list = abi.decode(raw, (AccountValue[]));
        for (uint256 i = 0; i < list.length; i++) dst.push(list[i]);
    }

    function _applyAll(
        StorageOverride[] storage storageList,
        AccountValue[] storage balanceList,
        AccountValue[] storage nonceList
    ) internal {
        for (uint256 i = 0; i < storageList.length; i++) {
            vm.store(storageList[i].account, storageList[i].slot, storageList[i].value);
        }
        for (uint256 i = 0; i < balanceList.length; i++) {
            vm.deal(balanceList[i].account, uint256(balanceList[i].value));
        }
        for (uint256 i = 0; i < nonceList.length; i++) {
            vm.setNonceUnsafe(nonceList[i].account, uint64(uint256(nonceList[i].value)));
        }
    }

    function _fundTakerUSDC(uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(taker, USDC_BALANCES_SLOT)), bytes32(amount));
        assertEq(IERC20(USDC).balanceOf(taker), amount, "USDC fund failed");
    }

    function _setMaxAllowance(address token, address owner, address spender) internal {
        bytes32 inner = keccak256(abi.encode(owner, USDC_ALLOWANCES_SLOT));
        vm.store(token, keccak256(abi.encode(spender, inner)), bytes32(type(uint256).max));
        assertEq(IERC20(token).allowance(owner, spender), type(uint256).max, "allowance set failed");
    }

    // ---- measurement ----

    function _direct(IPropAMMRouter.Venue venue) internal returns (uint256 gasUsed, uint256 out) {
        uint256 pre = IERC20(WETH).balanceOf(taker);
        vm.prank(taker);
        uint256 g = gasleft();
        out = router.swap(venue, USDC, WETH, AMOUNT_IN, 0, taker, UNI_FEE, block.timestamp + 120);
        gasUsed = g - gasleft();
        require(IERC20(WETH).balanceOf(taker) - pre == out, "direct delta mismatch");
    }

    function _wrap(IPropAMMRouter.Venue venue) internal returns (uint256 gasUsed, uint256 outUser, uint256 fee) {
        vm.prank(taker);
        uint256 g = gasleft();
        outUser = wrapper.swap(venue, USDC, WETH, AMOUNT_IN, 0, taker, UNI_FEE, block.timestamp + 120);
        gasUsed = g - gasleft();
        fee = IERC20(WETH).balanceOf(feeRecipient);
    }

    function _directWithFee(IPropAMMRouter.Venue venue)
        internal
        returns (uint256 gasUsed, uint256 outUser, uint256 fee)
    {
        vm.prank(taker);
        uint256 g = gasleft();
        outUser = routerWithFee.swap(venue, USDC, WETH, AMOUNT_IN, 0, taker, UNI_FEE, block.timestamp + 120);
        gasUsed = g - gasleft();
        fee = IERC20(WETH).balanceOf(feeRecipient);
    }

    /// @dev Collapses the 12 measurement values into one memory struct to keep
    /// the _venueRun stack frame from exceeding Solidity's 16-slot limit.
    struct VenueRunResult {
        uint256 gFb;
        uint256 outFb;
        uint256 gDir;
        uint256 outDir;
        uint256 gDirFee;
        uint256 outDirFeeUser;
        uint256 dirFee;
        uint256 gWrap;
        uint256 outUser;
        uint256 fee;
    }

    function _venueRun(
        string memory label,
        IPropAMMRouter.Venue venue,
        StorageOverride[] storage so,
        AccountValue[] storage ba,
        AccountValue[] storage no,
        uint256 freshBlock
    ) internal {
        if (!ready) return vm.skip(true);
        if (so.length == 0) {
            console.log(label);
            console.log("  SKIPPED: no Titan overrides for this venue");
            return vm.skip(true);
        }
        _applyAll(so, ba, no);
        vm.roll(freshBlock == 0 ? titanBlock : freshBlock);

        VenueRunResult memory r;
        uint256 snap = vm.snapshotState();

        (r.gFb, r.outFb) = _direct(IPropAMMRouter.Venue.Fallback);
        vm.revertToState(snap);

        (r.gDir, r.outDir) = _direct(venue);
        vm.revertToState(snap);

        (r.gDirFee, r.outDirFeeUser, r.dirFee) = _directWithFee(venue);
        vm.revertToState(snap);

        (r.gWrap, r.outUser, r.fee) = _wrap(venue);

        _logVenueRun(label, r);
    }

    function _logVenueRun(string memory label, VenueRunResult memory r) internal pure {
        console.log(label);
        console.log("  filled via propAMM (1=yes,0=fellback):", r.outDir != r.outFb ? 1 : 0);
        console.log("  direct         gas :", r.gDir);
        console.log("  directWithFee  gas :", r.gDirFee);
        console.log("  wrapper        gas :", r.gWrap);
        console.log("  OVERHEAD wrapper       - direct :", r.gWrap - r.gDir);
        console.log("  OVERHEAD directWithFee - direct :", r.gDirFee - r.gDir);
        console.log("  SAVINGS  wrapper       - dirFee :", r.gWrap - r.gDirFee);
        console.log("  out direct          (WETH wei):", r.outDir);
        console.log("  out directWithFee u (WETH wei):", r.outDirFeeUser);
        console.log("  out wrapper user    (WETH wei):", r.outUser);
        console.log("  fee directWithFee   (WETH wei):", r.dirFee);
        console.log("  fee wrapper         (WETH wei):", r.fee);
        console.log("  [ref] fallback gas :", r.gFb);
        console.log("  [ref] fallback out :", r.outFb);
    }

    function test_pammgas_fermi() public {
        _venueRun("[FermiSwap]", IPropAMMRouter.Venue.FermiSwap, fermiStorage, fermiBalances, fermiNonces, 0);
    }

    /// @notice Single-path mirror of `test_pammgas_kipseli_direct_only` for
    /// FermiSwap, so a `--flamegraph` run profiles just one `router.swap`.
    function test_pammgas_fermi_direct_only() public {
        if (!ready || fermiStorage.length == 0) return vm.skip(true);
        _applyAll(fermiStorage, fermiBalances, fermiNonces);
        vm.roll(titanBlock);

        (uint256 gDir, uint256 outDir) = _direct(IPropAMMRouter.Venue.FermiSwap);
        console.log("[FermiSwap] direct-only");
        console.log("  direct gas         :", gDir);
        console.log("  out (WETH wei)     :", outDir);
    }

    /// @notice Single-path mirror of `test_pammgas_kipseli_wrapper_only` for
    /// FermiSwap, so a `--flamegraph` run profiles just one `wrapper.swap`.
    function test_pammgas_fermi_wrapper_only() public {
        if (!ready || fermiStorage.length == 0) return vm.skip(true);
        _applyAll(fermiStorage, fermiBalances, fermiNonces);
        vm.roll(titanBlock);

        (uint256 gWrap, uint256 outUser, uint256 fee) = _wrap(IPropAMMRouter.Venue.FermiSwap);
        console.log("[FermiSwap] wrapper-only");
        console.log("  wrapper gas        :", gWrap);
        console.log("  out user (WETH wei):", outUser);
        console.log("  fee (WETH wei)     :", fee);
    }

    function test_pammgas_kipseli() public {
        _venueRun("[Kipseli]", IPropAMMRouter.Venue.Kipseli, kipseliStorage, kipseliBalances, kipseliNonces, 0);
    }


    /// @notice Single-path: ONLY the direct router swap through Kipseli, so a
    /// `--flamegraph` run profiles just that call. Applies the Kipseli overrides
    /// and rolls to the Titan block (Kipseli has no Bebop-style freshness gate),
    /// then performs exactly one `router.swap`.
    function test_pammgas_kipseli_direct_only() public {
        if (!ready || kipseliStorage.length == 0) return vm.skip(true);
        _applyAll(kipseliStorage, kipseliBalances, kipseliNonces);
        vm.roll(titanBlock);

        (uint256 gDir, uint256 outDir) = _direct(IPropAMMRouter.Venue.Kipseli);
        console.log("[Kipseli] direct-only");
        console.log("  direct gas         :", gDir);
        console.log("  out (WETH wei)     :", outDir);
    }

    /// @notice Single-path: ONLY the wrapper swap through Kipseli, for an
    /// isolated `--flamegraph` of the wrapper path. Exactly one `wrapper.swap`.
    function test_pammgas_kipseli_wrapper_only() public {
        if (!ready || kipseliStorage.length == 0) return vm.skip(true);
        _applyAll(kipseliStorage, kipseliBalances, kipseliNonces);
        vm.roll(titanBlock);

        (uint256 gWrap, uint256 outUser, uint256 fee) = _wrap(IPropAMMRouter.Venue.Kipseli);
        console.log("[Kipseli] wrapper-only");
        console.log("  wrapper gas        :", gWrap);
        console.log("  out user (WETH wei):", outUser);
        console.log("  fee (WETH wei)     :", fee);
    }


    function test_pammgas_bebop() public {
        uint256 fresh = vm.envOr("BEBOP_FRESH_BLOCK", uint256(0));
        _venueRun("[Bebop]", IPropAMMRouter.Venue.Bebop, bebopStorage, bebopBalances, bebopNonces, fresh);
    }

    /// @notice Single-path mirror for Bebop's direct router swap. Rolls to
    /// `BEBOP_FRESH_BLOCK` (Bebop's swap check is strict-equality on
    /// `block.number`); falls back to `titanBlock` if the env var is absent —
    /// same idiom as `test_pammgas_bebop`.
    function test_pammgas_bebop_direct_only() public {
        if (!ready || bebopStorage.length == 0) return vm.skip(true);
        _applyAll(bebopStorage, bebopBalances, bebopNonces);
        uint256 fresh = vm.envOr("BEBOP_FRESH_BLOCK", uint256(0));
        vm.roll(fresh == 0 ? titanBlock : fresh);

        (uint256 gDir, uint256 outDir) = _direct(IPropAMMRouter.Venue.Bebop);
        console.log("[Bebop] direct-only");
        console.log("  direct gas         :", gDir);
        console.log("  out (WETH wei)     :", outDir);
    }

    /// @notice Single-path mirror for Bebop's wrapper swap. Same freshness
    /// gate as `test_pammgas_bebop_direct_only`.
    function test_pammgas_bebop_wrapper_only() public {
        if (!ready || bebopStorage.length == 0) return vm.skip(true);
        _applyAll(bebopStorage, bebopBalances, bebopNonces);
        uint256 fresh = vm.envOr("BEBOP_FRESH_BLOCK", uint256(0));
        vm.roll(fresh == 0 ? titanBlock : fresh);

        (uint256 gWrap, uint256 outUser, uint256 fee) = _wrap(IPropAMMRouter.Venue.Bebop);
        console.log("[Bebop] wrapper-only");
        console.log("  wrapper gas        :", gWrap);
        console.log("  out user (WETH wei):", outUser);
        console.log("  fee (WETH wei)     :", fee);
    }
}
