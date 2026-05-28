// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {PropAMMFeeWrapper} from "../src/PropAMMFeeWrapper.sol";

/// @notice Realistic gas comparison on a mainnet fork. Deploys a REAL
/// PropAMMRouter and routes a WETH->USDC swap, once directly (no wrapper) and
/// once through the fee wrapper, for each venue.
///
///   ETH_RPC_URL=<mainnet> forge test \
///     --match-contract PropAMMFeeWrapperForkGasTest --fork-url $ETH_RPC_URL -vv
///
/// NOTE on proprietary venues: FermiSwap/Bebop keep liquidity off-chain, so on a
/// bare fork their venue call reverts and `swap`'s try/catch falls back to
/// Uniswap V3. The FermiSwap/Bebop numbers below therefore measure the
/// "attempt-proprietary-then-fallback" path, not a genuine RFQ fill — compare
/// the logged `out` to the Fallback arm: if equal, it fell back to Uni V3.
///
/// Self-skips when ETH_RPC_URL is unset, so a plain `forge test` is unaffected.
contract PropAMMFeeWrapperForkGasTest is Test {
    // Mainnet addresses (match contracts/scripts/Deploy.s.sol).
    address constant UNISWAP_V3_SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address constant UNISWAP_V3_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint24 constant FEE_TIER = 500; // USDC/WETH deepest pool is the 0.05% tier
    uint256 constant AMOUNT_IN = 1 ether;
    uint16 constant FEE_BPS = 50; // 0.5%

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address user = makeAddr("user");

    bool forked;
    PropAMMRouter router;

    function setUp() public {
        try vm.envString("ETH_RPC_URL") returns (string memory rpc) {
            vm.createSelectFork(rpc);
            forked = true;
            PropAMMRouter impl = new PropAMMRouter();
            router = PropAMMRouter(address(new ERC1967Proxy(
                address(impl),
                abi.encodeCall(PropAMMRouter.initialize, (UNISWAP_V3_SWAP_ROUTER, UNISWAP_V3_QUOTER, owner))
            )));
        } catch {
            forked = false;
        }
    }

    function _deployWrapper(uint16 feeBps) internal returns (PropAMMFeeWrapper) {
        PropAMMFeeWrapper impl = new PropAMMFeeWrapper();
        return PropAMMFeeWrapper(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PropAMMFeeWrapper.initialize, (address(router), feeRecipient, feeBps, owner))
        )));
    }

    // Direct: user approves the router and swaps; output goes to user.
    function _direct(IPropAMMRouter.Venue venue) internal returns (uint256 gasUsed, uint256 out) {
        deal(WETH, user, AMOUNT_IN);
        vm.prank(user);
        IERC20(WETH).approve(address(router), AMOUNT_IN);

        vm.prank(user);
        uint256 g = gasleft();
        out = router.swap(venue, WETH, USDC, AMOUNT_IN, 0, user, FEE_TIER, block.timestamp + 1);
        gasUsed = g - gasleft();
    }

    // Wrapper: user approves the wrapper; it pulls, calls the router, splits fee + net.
    function _wrapper(IPropAMMRouter.Venue venue, uint16 feeBps)
        internal
        returns (uint256 gasUsed, uint256 out, uint256 fee)
    {
        PropAMMFeeWrapper wrapper = _deployWrapper(feeBps);
        deal(WETH, user, AMOUNT_IN);
        vm.prank(user);
        IERC20(WETH).approve(address(wrapper), AMOUNT_IN);

        vm.prank(user);
        uint256 g = gasleft();
        out = wrapper.swap(venue, WETH, USDC, AMOUNT_IN, 0, user, FEE_TIER, block.timestamp + 1);
        gasUsed = g - gasleft();
        fee = IERC20(USDC).balanceOf(feeRecipient);
    }

    function _logDirect(string memory label, IPropAMMRouter.Venue venue) internal {
        (uint256 gasUsed, uint256 out) = _direct(venue);
        console.log(label);
        console.log("  direct gas :", gasUsed);
        console.log("  USDC out   :", out);
    }

    function _logWrapper(string memory label, IPropAMMRouter.Venue venue) internal {
        (uint256 gasUsed, uint256 out, uint256 fee) = _wrapper(venue, FEE_BPS);
        console.log(label);
        console.log("  wrapper gas:", gasUsed);
        console.log("  USDC user  :", out);
        console.log("  USDC fee   :", fee);
    }

    // ----- Fallback (Uniswap V3) -----
    function test_gas_fallback_direct() public {
        if (!forked) return vm.skip(true);
        _logDirect("[Fallback] direct router.swap", IPropAMMRouter.Venue.Fallback);
    }

    function test_gas_fallback_wrapper() public {
        if (!forked) return vm.skip(true);
        _logWrapper("[Fallback] wrapper.swap (fee=0.5%)", IPropAMMRouter.Venue.Fallback);
    }

    // ----- FermiSwap (expect off-chain liquidity miss -> Uni V3 fallback) -----
    function test_gas_fermi_direct() public {
        if (!forked) return vm.skip(true);
        _logDirect("[FermiSwap] direct router.swap", IPropAMMRouter.Venue.FermiSwap);
    }

    function test_gas_fermi_wrapper() public {
        if (!forked) return vm.skip(true);
        _logWrapper("[FermiSwap] wrapper.swap (fee=0.5%)", IPropAMMRouter.Venue.FermiSwap);
    }

    // ----- Bebop (no recipient arg + off-chain liquidity -> Uni V3 fallback) -----
    function test_gas_bebop_direct() public {
        if (!forked) return vm.skip(true);
        _logDirect("[Bebop] direct router.swap", IPropAMMRouter.Venue.Bebop);
    }

    function test_gas_bebop_wrapper() public {
        if (!forked) return vm.skip(true);
        _logWrapper("[Bebop] wrapper.swap (fee=0.5%)", IPropAMMRouter.Venue.Bebop);
    }
}
