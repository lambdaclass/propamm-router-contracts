// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {UniV3Adapter} from "../src/libraries/UniV3Adapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import {USDC, USDT, WETH} from "../src/libraries/Constants.sol";
import "../src/libraries/Errors.sol";

/// @title PropAMMRouterCallbackTest
/// @notice Guards the security crux of the direct core-pool fallback: the
/// `uniswapV3SwapCallback` authentication (only a genuine pool may invoke it) and
/// the `computePool` derivation it authenticates against.
contract PropAMMRouterCallbackTest is Test {
    PropAMMRouter internal router;
    AccessManager internal manager;
    MockQuoterV2 internal quoter;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(this);
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public {
        quoter = new MockQuoterV2();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory init = abi.encodeCall(PropAMMRouter.initialize, (address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), init))));
    }

    // --- computePool correctness oracle -----------------------------------
    // Pins the factory address, pool init-code hash, and token sorting against
    // real mainnet pools. If any of those is wrong, every fallback swap reverts.

    function test_computePool_matchesMainnetPools() public pure {
        // USDC/WETH 0.05%
        assertEq(UniV3Adapter.computePool(USDC, WETH, 500), 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
        // USDC/USDT 0.01%
        assertEq(UniV3Adapter.computePool(USDC, USDT, 100), 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6);
    }

    function test_computePool_orderIndependent() public pure {
        assertEq(UniV3Adapter.computePool(WETH, USDC, 500), UniV3Adapter.computePool(USDC, WETH, 500));
    }

    // --- callback authentication (the OnlyPool guard) ---------------------

    /// @dev Encodes the `(tokenIn, tokenOut, fee, payer, amountIn)` tuple the
    /// callback decodes, with the test tokens and a chosen `payer`.
    function _callbackData(address payer) internal view returns (bytes memory) {
        return abi.encode(address(tokenIn), address(tokenOut), uint24(3000), payer, uint256(100));
    }

    function test_callback_directCallReverts() public {
        // The caller is not the canonical pool for the encoded (tokenIn, tokenOut,
        // fee), so the guard rejects it — the callback can't run outside a real
        // pool's swap, no matter the deltas supplied.
        vm.prank(attacker);
        vm.expectRevert(OnlyPool.selector);
        router.uniswapV3SwapCallback(int256(100), -int256(50), _callbackData(attacker));
    }

    function test_callback_cannotPullArbitraryPayer() public {
        // A victim with a standing max approval to the router...
        tokenIn.mint(victim, 1_000e18);
        vm.prank(victim);
        tokenIn.approve(address(router), type(uint256).max);

        // ...cannot be drained by an attacker invoking the callback directly with
        // payer = victim: the pool-address guard reverts before any transferFrom,
        // so the callback is not a usable `transferFrom` primitive.
        vm.prank(attacker);
        vm.expectRevert(OnlyPool.selector);
        router.uniswapV3SwapCallback(int256(100), -int256(50), _callbackData(victim));

        assertEq(tokenIn.balanceOf(victim), 1_000e18, "victim funds must be untouched");
    }
}
