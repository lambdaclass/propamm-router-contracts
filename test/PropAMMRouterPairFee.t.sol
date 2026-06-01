// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter02} from "./mocks/MockSwapRouter02.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";

contract PropAMMRouterPairFeeTest is Test {
    PropAMMRouter internal router;
    MockSwapRouter02 internal mockRouter;
    MockQuoterV2 internal mockQuoter;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(this);
    address internal stranger = address(0xBEEF); // used by setPairFee/setPairFees access-control tests in later tasks
    address internal recipient = address(0xCAFE);

    // Re-declared locally so vm.expectEmit can match the router's emit.
    // Mirror of PropAMMRouter.PairFeeUpdated (added in Task 3); kept in sync so vm.expectEmit matches.
    event PairFeeUpdated(address indexed tokenA, address indexed tokenB, uint24 oldFee, uint24 newFee);

    function setUp() public {
        mockRouter = new MockSwapRouter02();
        mockQuoter = new MockQuoterV2();
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(mockRouter), address(mockQuoter), owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(address(proxy));
    }

    function test_setUp_initialized() public view {
        assertEq(router.owner(), owner);
        assertEq(router.fallbackFee(), 3000);
        assertEq(router.fallbackSwapRouter(), address(mockRouter));
        assertEq(router.fallbackQuoter(), address(mockQuoter));
    }

    function test_resolvedFee_unset_returnsGlobalDefault() public view {
        assertEq(router.resolvedFee(address(tokenIn), address(tokenOut)), 3000);
    }

    function test_getPairFee_unset_returnsZero() public view {
        assertEq(router.getPairFee(address(tokenIn), address(tokenOut)), 0);
    }

    function test_resolvedFee_reversed_unset_returnsGlobalDefault() public view {
        assertEq(router.resolvedFee(address(tokenOut), address(tokenIn)), 3000);
    }

    function test_getPairFee_reversed_unset_returnsZero() public view {
        assertEq(router.getPairFee(address(tokenOut), address(tokenIn)), 0);
    }

    function test_setPairFee_setsAndResolves() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        assertEq(router.resolvedFee(address(tokenIn), address(tokenOut)), 100);
        assertEq(router.getPairFee(address(tokenIn), address(tokenOut)), 100);
    }

    function test_setPairFee_isOrderIndependent() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        assertEq(router.resolvedFee(address(tokenOut), address(tokenIn)), 100);
        assertEq(router.getPairFee(address(tokenOut), address(tokenIn)), 100);
    }

    function test_setPairFee_clearWithZero() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        router.setPairFee(address(tokenIn), address(tokenOut), 0);
        assertEq(router.resolvedFee(address(tokenIn), address(tokenOut)), 3000);
        assertEq(router.getPairFee(address(tokenIn), address(tokenOut)), 0);
    }

    function test_setPairFee_revertsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(PropAMMRouter.InvalidFallbackFee.selector, uint24(1_000_000)));
        router.setPairFee(address(tokenIn), address(tokenOut), 1_000_000);
    }

    function test_setPairFee_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(router));
        emit PairFeeUpdated(address(tokenIn), address(tokenOut), 0, 100);
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
    }

    function test_setPairFee_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
    }

    function test_setPairFee_emitsEventWithPriorFeeAsOld() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        vm.expectEmit(true, true, false, true, address(router));
        emit PairFeeUpdated(address(tokenIn), address(tokenOut), 100, 500);
        router.setPairFee(address(tokenIn), address(tokenOut), 500);
    }
}
