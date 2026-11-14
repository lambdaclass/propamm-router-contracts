// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {ForkGate} from "./helpers/ForkGate.sol";

/// @title PropAMMRouterSplitFork
/// @notice Live-venue coverage for `swapSplitV1`: deploys a fresh router against
/// the real mainnet fallback (SwapRouter02 + QuoterV2) and the seven real
/// propAMMs, then exercises the split against whatever those venues are
/// actually quoting at the fork block.
///
/// @dev Deliberately carries `Fork` in the filename so `--no-match-path
/// '*Fork*'` excludes it from the PR gate (see `ForkGate`). This is a
/// SEPARATE suite from `test/PropAMMRouterForkTests.t.sol`: that file targets
/// the already-deployed demo router and predates this branch; this one deploys
/// its own router to exercise `swapSplitV1`, which the demo router does not
/// carry.
contract PropAMMRouterSplitForkTest is ForkGate {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNISWAP_ROUTER_02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    /// @dev Mainnet Uniswap V3 QuoterV2. Not in README's "Deployed Contracts"
    /// table (that table lists only the propAMMs + the fallback router this
    /// repo owns) — taken instead from `scripts/Deploy.s.sol`, this repo's own
    /// deployment script, which wires the same address in as `quoter`.
    address constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    // The seven propAMMs from README.md's "Deployed Contracts" section.
    address constant BEBOP = 0xB09AaA5614916d7AEb59C295C52c92ca82aDdD76;
    address constant FERMI = 0x5979458912F80B96d30D4220af8E2e4925A33320;
    address constant KIPSELI = 0x71e790dd841c8A9061487cb3E78C288E75cE0B3d;
    address constant TEMPEST = 0x00000003f1ec2379e79F58E12EC6C4F51Ee92149;
    address constant TAURUSFI = 0x217d58931A8549ca539426AA8152E33dAfc3d95A;
    address constant METRIC = 0xE715Dc29d2c273D0FC5A03e5Cca9CcB0Abb1dCDB;
    address constant EL_ZORRO = 0xCF211B4dD0D2be5C173Ea57Bcf938FC61d1d3bd3;

    /// @dev USDC (FiatTokenV2_2) storage layout, same as `PropAMMRouterForkTests`.
    uint256 constant USDC_BALANCES_SLOT = 9;
    uint256 constant USDC_ALLOWANCES_SLOT = 10;

    /// @dev Sized so both `SPLIT_AMOUNT` and `WORST_CASE_AMOUNT` below fit
    /// comfortably with room to spare.
    uint256 constant TAKER_USDC = 3_000_000e6;

    /// @dev Order size for the "does the split beat/match all-Uniswap" check —
    /// a moderate size seen throughout this repo's gas benchmarking (see
    /// `gas-analysis-findings`).
    uint256 constant SPLIT_AMOUNT = 10_000e6;

    /// @dev Order size for the worst-case probe-gas measurement. Deliberately
    /// large: the §9.1 worst case requires every venue to be SATURATED at both
    /// probe points (`p` and `p/2`), which only happens when `p` clears the
    /// venue's real capacity by more than 2x. A big order maximizes the odds
    /// that whatever thin depth is live right now gets caught saturating
    /// rather than simply quoting cleanly (2 quotes, no descent) or reverting
    /// outright (also 2 quotes, no descent, no candidate).
    uint256 constant WORST_CASE_AMOUNT = 1_000_000e6;

    PropAMMRouter router;
    address taker = makeAddr("splitForkTaker");

    function setUp() public {
        if (!_selectForkOrSkip()) return;

        AccessManager manager = new AccessManager(address(this));
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (UNISWAP_ROUTER_02, QUOTER_V2, address(manager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(payable(address(proxy)));

        address[7] memory venues = _venues();
        for (uint256 i = 0; i < venues.length; i++) {
            router.addVenue(venues[i]);
        }
        require(router.whitelistedVenueCount() == 7, "expected all 7 propAMMs listed");
        require(router.isSplitAvailable(), "split unavailable past MAX_SPLIT_VENUES");

        _fundTakerUSDC(TAKER_USDC);
        _setMaxAllowance(USDC, taker, address(router));
        vm.deal(taker, 10 ether);
    }

    function _venues() internal pure returns (address[7] memory) {
        return [BEBOP, FERMI, KIPSELI, TEMPEST, TAURUSFI, METRIC, EL_ZORRO];
    }

    /// @notice Executes a real USDC -> WETH split and asserts it delivers at
    /// least what an all-Uniswap route would, deriving the Uniswap figure LIVE
    /// (via `quoteVenueV1` naming the fallback) rather than hardcoding it.
    /// @dev Skips — does not fail — when no propAMM is quotable at the fork
    /// block. That is expected today: the spec's §9.3 records Fermi dark since
    /// ~2026-09-09, and this repo's own live sampling (see
    /// `gas-analysis-findings`) never caught two venues simultaneously
    /// quotable across two full campaigns. A router regression and ordinary
    /// venue staleness produce the identical on-chain symptom (every propAMM
    /// quote reverts), so only a skip is honest here — an assertion that
    /// happened to pass would prove nothing, and one written to fail on "zero
    /// candidates" would flag market conditions as a router bug.
    function test_splitMatchesOrBeatsLiveUniswap() public {
        (uint256 quotable,) = _diagnoseVenues(SPLIT_AMOUNT);
        console2.log(string.concat("RESULT|split_live_quotable_venues|", vm.toString(quotable)));
        if (quotable == 0) {
            vm.skip(true, "no propAMM venue is quotable at this fork block (see design spec Sec9.3)");
            return;
        }

        (uint256 uniOnly,) = router.quoteVenueV1(UNISWAP_ROUTER_02, USDC, WETH, SPLIT_AMOUNT);

        vm.recordLogs();
        vm.prank(taker);
        uint256 amountOut = router.swapSplitV1(USDC, WETH, SPLIT_AMOUNT, 0, taker, block.timestamp + 300);
        uint256 propAmmLegs = _countPropAmmLegs(vm.getRecordedLogs());

        assertGe(amountOut, uniOnly, "split underdelivered vs. a live all-Uniswap route");
        assertEq(IERC20(WETH).balanceOf(taker), amountOut, "amountOut != recipient balance delta");

        console2.log(string.concat("RESULT|split_real_amount_out|", vm.toString(amountOut)));
        console2.log(string.concat("RESULT|split_real_uniswap_only_out|", vm.toString(uniOnly)));
        console2.log(string.concat("RESULT|split_real_propamm_legs_filled|", vm.toString(propAmmLegs)));
    }

    /// @notice THE MERGE GATE. Same shape as `test_split_worstCaseProbeGas` in
    /// the mock suite, run against the seven real venues: measures the gas
    /// `swapSplitV1` actually spends probing them, which is what decides
    /// whether the §9.1 worst case (12 x (2+8) = 120 venue quotes, reachable
    /// when every venue saturates at both probe points and none implements
    /// `IPropAMMFillable`) fits inside the 30,000,000 block gas limit.
    ///
    /// @dev IMPORTANT CAVEAT, read before trusting this number: it can only
    /// measure what today's seven real venues actually do. None of them
    /// implement `IPropAMMFillable` (it is a new extension this branch adds;
    /// no pre-existing external propAMM could have implemented it), so that
    /// half of the worst-case precondition holds unconditionally. But
    /// "saturated at both probe points" requires a venue to be quotable AND
    /// capacity-capped well under `WORST_CASE_AMOUNT` — this repo's own
    /// sampling (see `gas-analysis-findings`) shows venues are frequently
    /// quotable in NONE of a fork block's natural `eth_call`s (no
    /// Titan/builder overrides), only 7 whitelisted venues exist (not 12), and
    /// even a live venue may quote cleanly rather than saturate. The
    /// `RESULT|split_worst_case_probe_gas_real_quotable_venues|` and
    /// `..._saturating_venues|` lines report exactly how many of the 7 venues
    /// this run actually caught in each state, so the gate number can be read
    /// alongside how much of the true worst-case shape it actually covers. A
    /// run that catches zero saturating venues UNDERSTATES true worst-case gas
    /// (a revert is far cheaper than a real saturating quote — some venues
    /// price by simulating an actual swap) and a comfortable pass in that case
    /// is not proof the design is safe, only that today's network conditions
    /// didn't test it.
    function test_split_worstCaseProbeGasReal() public {
        (uint256 quotable, uint256 saturating) = _diagnoseVenues(WORST_CASE_AMOUNT);
        console2.log(string.concat("RESULT|split_worst_case_probe_gas_real_quotable_venues|", vm.toString(quotable)));
        console2.log(
            string.concat("RESULT|split_worst_case_probe_gas_real_saturating_venues|", vm.toString(saturating))
        );

        vm.prank(taker);
        uint256 g0 = gasleft();
        router.swapSplitV1(USDC, WETH, WORST_CASE_AMOUNT, 0, taker, block.timestamp + 300);
        uint256 used = g0 - gasleft();

        console2.log(string.concat("RESULT|split_worst_case_probe_gas_real|", vm.toString(used)));
        assertLt(used, 30_000_000, "real worst-case probe gas exceeds the block gas limit");
    }

    /// @dev Probes every whitelisted propAMM at `amountIn` and `amountIn / 2`
    /// the same way `_probeVenue` does internally, purely to characterize
    /// market conditions before trusting an assertion or a gas number derived
    /// from them.
    /// @return quotable Venues returning a nonzero quote at either point.
    /// @return saturating Venues quoting the SAME nonzero output at both
    /// points — i.e. venues that would trigger the real 8-step downward probe.
    function _diagnoseVenues(uint256 amountIn) internal returns (uint256 quotable, uint256 saturating) {
        address[7] memory vs = _venues();
        for (uint256 i = 0; i < vs.length; i++) {
            uint256 outFull = _tryQuote(vs[i], amountIn);
            uint256 outHalf = _tryQuote(vs[i], amountIn / 2);
            if (outFull > 0 || outHalf > 0) quotable++;
            if (outFull > 0 && outFull == outHalf) saturating++;
        }
    }

    function _tryQuote(address venue, uint256 amountIn) internal returns (uint256 out) {
        try router.quoteVenueV1(venue, USDC, WETH, amountIn) returns (uint256 amountOut_, address) {
            out = amountOut_;
        } catch {
            out = 0;
        }
    }

    /// @dev Counts `Swapped` events whose `marketMaker` is a propAMM rather
    /// than the Uniswap fallback, i.e. legs that actually filled via a real
    /// venue instead of being absorbed into the coalesced Uniswap remainder.
    function _countPropAmmLegs(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IPropAMMRouter.Swapped.selector) {
                (,,, address marketMaker) = abi.decode(logs[i].data, (uint256, uint256, address, address));
                if (marketMaker != UNISWAP_ROUTER_02) count++;
            }
        }
    }

    /// @dev (Re)funds `taker` with USDC by writing its balance slot directly,
    /// same technique as `PropAMMRouterForkTests._fundTakerUSDC`.
    function _fundTakerUSDC(uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(taker, USDC_BALANCES_SLOT));
        vm.store(USDC, slot, bytes32(amount));
        assertEq(IERC20(USDC).balanceOf(taker), amount, "USDC fund failed");
    }

    function _setMaxAllowance(address token, address owner, address spender) internal {
        bytes32 inner = keccak256(abi.encode(owner, USDC_ALLOWANCES_SLOT));
        bytes32 slot = keccak256(abi.encode(spender, inner));
        vm.store(token, slot, bytes32(type(uint256).max));
        assertEq(IERC20(token).allowance(owner, spender), type(uint256).max, "allowance set failed");
    }
}
