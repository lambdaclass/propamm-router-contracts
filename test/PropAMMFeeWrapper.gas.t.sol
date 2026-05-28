// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMFeeWrapper} from "../src/PropAMMFeeWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPropAMMRouter} from "./mocks/MockPropAMMRouter.sol";

/// @notice Measures the gas overhead of routing a swap THROUGH PropAMMFeeWrapper
/// versus calling the underlying router DIRECTLY. Both arms drive the SAME
/// MockPropAMMRouter (identical transferFrom-in / transfer-out behavior), so the
/// venue/swap cost is identical and the delta between arms is purely the wrapper's
/// added work: the extra caller->wrapper transferFrom, the forceApprove, the fee
/// split transfers, plus the whenNotPaused / nonReentrant modifiers.
///
/// Each measurement runs in its own test function so forge gives it fresh state
/// (all storage cold) — keeping the direct vs wrapper comparison apples-to-apples.
/// Read the numbers with:
///
///   forge test --match-contract PropAMMFeeWrapperGasTest -vv
///
/// NOTE: absolute overhead depends on the real tokens' warm/cold storage in
/// production (e.g. whether feeRecipient already holds tokenOut). For real-world
/// numbers, measure wrapper.swap vs router.swap on a mainnet fork with the Uniswap
/// V3 fallback (see MANUAL_TEST.md). This test isolates the structural overhead.
contract PropAMMFeeWrapperGasTest is Test {
    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address user = makeAddr("user");

    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant ROUTER_OUT = 1_000e18;

    function _newRouter() internal returns (MockPropAMMRouter r, MockERC20 tIn, MockERC20 tOut) {
        r = new MockPropAMMRouter();
        tIn = new MockERC20("In", "IN");
        tOut = new MockERC20("Out", "OUT");
        r.setAmountOut(ROUTER_OUT);
    }

    function _deployWrapper(address router_, uint16 feeBps) internal returns (PropAMMFeeWrapper) {
        PropAMMFeeWrapper impl = new PropAMMFeeWrapper();
        bytes memory data =
            abi.encodeCall(PropAMMFeeWrapper.initialize, (router_, feeRecipient, feeBps, owner));
        return PropAMMFeeWrapper(address(new ERC1967Proxy(address(impl), data)));
    }

    /// Baseline: user approves the router and swaps directly; output goes to user.
    function _measureDirect() internal returns (uint256 used) {
        (MockPropAMMRouter r, MockERC20 tIn, MockERC20 tOut) = _newRouter();
        tIn.mint(user, AMOUNT_IN);
        tOut.mint(address(r), ROUTER_OUT);
        vm.prank(user);
        tIn.approve(address(r), AMOUNT_IN);

        vm.prank(user);
        uint256 g = gasleft();
        r.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tIn), address(tOut),
            AMOUNT_IN, 0, user, uint24(3000), block.timestamp + 1
        );
        used = g - gasleft();
    }

    /// Wrapper: user approves the wrapper, which pulls funds, calls the router, and
    /// splits the output into fee + net.
    function _measureWrapper(uint16 feeBps) internal returns (uint256 used) {
        (MockPropAMMRouter r, MockERC20 tIn, MockERC20 tOut) = _newRouter();
        PropAMMFeeWrapper w = _deployWrapper(address(r), feeBps);
        tIn.mint(user, AMOUNT_IN);
        tOut.mint(address(r), ROUTER_OUT);
        vm.prank(user);
        tIn.approve(address(w), AMOUNT_IN);

        vm.prank(user);
        uint256 g = gasleft();
        w.swap(
            IPropAMMRouter.Venue.FermiSwap, address(tIn), address(tOut),
            AMOUNT_IN, 0, user, uint24(3000), block.timestamp + 1
        );
        used = g - gasleft();
    }

    function test_gas_directRouterSwap() public {
        console.log("direct router.swap       :", _measureDirect());
    }

    function test_gas_wrapperSwap_withFee() public {
        console.log("wrapper.swap (fee = 0.5%):", _measureWrapper(50));
    }

    function test_gas_wrapperSwap_zeroFee() public {
        console.log("wrapper.swap (fee = 0)   :", _measureWrapper(0));
    }
}
