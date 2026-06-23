// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter02} from "./mocks/MockSwapRouter02.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import "../src/libraries/Errors.sol";

contract PropAMMRouterPairFeeTest is Test {
    PropAMMRouter internal router;
    AccessManager internal manager;
    MockSwapRouter02 internal mockRouter;
    MockQuoterV2 internal mockQuoter;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;

    address internal owner = address(this);
    address internal stranger = address(0xBEEF); // used by setPairFee/setPairFees access-control tests in later tasks
    address internal recipient = address(0xCAFE);

    // Mainnet token addresses seeded as defaults by `initialize` (mirror of the
    // contract's private constants; kept in sync so the seed assertions match).
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Re-declared locally so vm.expectEmit can match the router's emit.
    // Mirror of PropAMMRouter.PairFeeUpdated (added in Task 3); kept in sync so vm.expectEmit matches.
    event PairFeeUpdated(address indexed tokenA, address indexed tokenB, uint24 oldFee, uint24 newFee);

    function setUp() public {
        mockRouter = new MockSwapRouter02();
        mockQuoter = new MockQuoterV2();
        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        // Plain AccessManager with `owner` as delay-0 admin: unmapped selectors
        // default to ADMIN_ROLE, so `owner` can call every `restricted` function
        // directly while anyone else gets AccessManagedUnauthorized.
        manager = new AccessManager(owner);

        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(mockRouter), address(mockQuoter), address(manager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(payable(address(proxy)));
    }

    function test_setUp_initialized() public view {
        assertEq(router.authority(), address(manager));
        assertEq(router.fallbackFee(), 3000);
        assertEq(router.fallbackSwapRouter(), address(mockRouter));
        assertEq(router.fallbackQuoter(), address(mockQuoter));
    }

    function test_initialize_seedsDefaultPairFees() public view {
        // A from-scratch deploy (the proxy in setUp) is configured with the deep
        // mainnet tiers without any owner action after init.
        assertEq(router.getPairFee(USDT, USDC), 100);
        assertEq(router.getPairFee(USDT, WETH), 500);
        assertEq(router.getPairFee(USDC, WETH), 500);

        assertEq(router.resolvedFee(USDT, USDC), 100);
        assertEq(router.resolvedFee(USDT, WETH), 500);
        assertEq(router.resolvedFee(USDC, WETH), 500);

        // Order-independence holds for the seeded pairs too.
        assertEq(router.resolvedFee(USDC, USDT), 100);
        assertEq(router.resolvedFee(WETH, USDT), 500);
        assertEq(router.resolvedFee(WETH, USDC), 500);
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
        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackFee.selector, uint24(1_000_000)));
        router.setPairFee(address(tokenIn), address(tokenOut), 1_000_000);
    }

    function test_setPairFee_acceptsMaxValidFee() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 999_999);
        assertEq(router.getPairFee(address(tokenIn), address(tokenOut)), 999_999);
        assertEq(router.resolvedFee(address(tokenIn), address(tokenOut)), 999_999);
    }

    function test_setPairFee_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(router));
        emit PairFeeUpdated(address(tokenIn), address(tokenOut), 0, 100);
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
    }

    function test_setPairFee_onlyAuthorized() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
    }

    function test_setPairFee_emitsEventWithPriorFeeAsOld() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        vm.expectEmit(true, true, false, true, address(router));
        emit PairFeeUpdated(address(tokenIn), address(tokenOut), 100, 500);
        router.setPairFee(address(tokenIn), address(tokenOut), 500);
    }

    function test_setPairFees_batchSets() public {
        address[] memory a = new address[](2);
        address[] memory b = new address[](2);
        uint24[] memory f = new uint24[](2);
        a[0] = address(tokenIn);
        b[0] = address(tokenOut);
        f[0] = 100;
        a[1] = address(tokenOut);
        b[1] = address(0x1234);
        f[1] = 500;

        router.setPairFees(a, b, f);

        assertEq(router.resolvedFee(address(tokenIn), address(tokenOut)), 100);
        assertEq(router.resolvedFee(address(tokenOut), address(0x1234)), 500);
    }

    function test_setPairFees_emitsPerPair() public {
        address[] memory a = new address[](2);
        address[] memory b = new address[](2);
        uint24[] memory f = new uint24[](2);
        a[0] = address(tokenIn);
        b[0] = address(tokenOut);
        f[0] = 100;
        a[1] = address(tokenOut);
        b[1] = address(0x1234);
        f[1] = 500;

        vm.expectEmit(true, true, false, true, address(router));
        emit PairFeeUpdated(address(tokenIn), address(tokenOut), 0, 100);
        vm.expectEmit(true, true, false, true, address(router));
        emit PairFeeUpdated(address(tokenOut), address(0x1234), 0, 500);

        router.setPairFees(a, b, f);
    }

    function test_setPairFees_lengthMismatchReverts() public {
        address[] memory a = new address[](2);
        address[] memory b = new address[](1);
        uint24[] memory f = new uint24[](2);
        vm.expectRevert(ArrayLengthMismatch.selector);
        router.setPairFees(a, b, f);
    }

    function test_setPairFees_invalidFeeInSlotReverts() public {
        address[] memory a = new address[](1);
        address[] memory b = new address[](1);
        uint24[] memory f = new uint24[](1);
        a[0] = address(tokenIn);
        b[0] = address(tokenOut);
        f[0] = 1_000_000;
        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackFee.selector, uint24(1_000_000)));
        router.setPairFees(a, b, f);
    }

    function test_setPairFees_onlyAuthorized() public {
        address[] memory a = new address[](0);
        address[] memory b = new address[](0);
        uint24[] memory f = new uint24[](0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        router.setPairFees(a, b, f);
    }

    function test_setPairFees_midBatchInvalidFeeRevertsAll() public {
        address[] memory a = new address[](2);
        address[] memory b = new address[](2);
        uint24[] memory f = new uint24[](2);
        a[0] = address(tokenIn); // valid
        b[0] = address(tokenOut);
        f[0] = 100;
        a[1] = address(tokenOut); // invalid
        b[1] = address(0x1234);
        f[1] = 1_000_000;

        vm.expectRevert(abi.encodeWithSelector(InvalidFallbackFee.selector, uint24(1_000_000)));
        router.setPairFees(a, b, f);

        // entry 0 must NOT have been committed (whole batch rolled back)
        assertEq(router.getPairFee(address(tokenIn), address(tokenOut)), 0);
    }

    function test_quoteUniswapV3_usesResolvedFee() public {
        mockQuoter.setAmountOut(1000);
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        router.quoteVenueV1(router.fallbackSwapRouter(), address(tokenIn), address(tokenOut), 1 ether);
        assertEq(mockQuoter.lastFee(), 100);
    }

    function test_quoteUniswapV3_unconfigured_usesGlobalFee() public {
        mockQuoter.setAmountOut(1000);
        router.quoteVenueV1(router.fallbackSwapRouter(), address(tokenIn), address(tokenOut), 1 ether);
        assertEq(mockQuoter.lastFee(), 3000);
    }

    function test_quoteVenueV1_fallback_usesResolvedFee() public {
        mockQuoter.setAmountOut(1000);
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        router.quoteVenueV1(address(mockRouter), address(tokenIn), address(tokenOut), 1 ether);
        assertEq(mockQuoter.lastFee(), 100);
    }

    function test_swapViaFallback_usesResolvedFee() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        mockRouter.setAmountOut(1000);
        tokenIn.mint(address(this), 1000);
        tokenIn.approve(address(router), 1000);

        router.swapViaVenueV1(
            address(mockRouter), address(tokenIn), address(tokenOut), 1000, 900, recipient, block.timestamp + 1
        );

        assertEq(mockRouter.lastFee(), 100);
        assertEq(tokenOut.balanceOf(recipient), 1000);
    }

    function test_swapViaFallback_unconfigured_usesGlobalFee() public {
        mockRouter.setAmountOut(1000);
        tokenIn.mint(address(this), 1000);
        tokenIn.approve(address(router), 1000);

        router.swapViaVenueV1(
            address(mockRouter), address(tokenIn), address(tokenOut), 1000, 900, recipient, block.timestamp + 1
        );

        assertEq(mockRouter.lastFee(), 3000);
    }

    function test_swapV1_fallbackWins_usesResolvedFee() public {
        router.setPairFee(address(tokenIn), address(tokenOut), 100);
        mockQuoter.setAmountOut(1000); // fallback quote wins the auction
        mockRouter.setAmountOut(1000); // fallback execution delivers tokenOut
        tokenIn.mint(address(this), 1000);
        tokenIn.approve(address(router), 1000);

        (uint256 amountOut, address executedVenue) =
            router.swapV1(address(tokenIn), address(tokenOut), 1000, 900, recipient, block.timestamp + 1);

        assertEq(mockRouter.lastFee(), 100); // executed at the resolved per-pair tier
        assertEq(executedVenue, address(mockRouter)); // fallbackSwapRouter won
        assertEq(amountOut, 1000);
        assertEq(tokenOut.balanceOf(recipient), 1000);
    }

    function test_seedStablePairs_resolveToSeededTiers() public {
        address[] memory a = new address[](3);
        address[] memory b = new address[](3);
        uint24[] memory f = new uint24[](3);

        // USDC/USDT — stablecoin pair, deepest at 0.01%.
        a[0] = USDC;
        b[0] = USDT;
        f[0] = 100;
        // USDC/WETH — ETH/stable, deepest at 0.05%.
        a[1] = USDC;
        b[1] = WETH;
        f[1] = 500;
        // USDT/WETH — ETH/stable, deepest at 0.05%.
        a[2] = USDT;
        b[2] = WETH;
        f[2] = 500;

        router.setPairFees(a, b, f);

        for (uint256 i = 0; i < a.length; i++) {
            assertEq(router.resolvedFee(a[i], b[i]), f[i]);
            assertEq(router.getPairFee(a[i], b[i]), f[i]);
            // order-independence holds for the seeded pairs too
            assertEq(router.resolvedFee(b[i], a[i]), f[i]);
        }
    }
}
