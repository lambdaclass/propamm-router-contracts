// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {MockPropAMM} from "./mocks/MockPropAMM.sol";
import {MockSwapRouter, MockQuoter} from "./mocks/MockUniswap.sol";

/// @notice Shared setup: deploys a `PropAMMRouter` behind an ERC-1967 proxy,
/// wired to a mock Uniswap fallback (swap router + quoter) and two test tokens.
/// The implementation's constructor calls `_disableInitializers`, so the
/// contract is only usable through the proxy — matching production.
contract BaseTest is Test {
    PropAMMRouter internal router;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal user = makeAddr("user");

    TestERC20 internal tokenIn;
    TestERC20 internal tokenOut;

    MockSwapRouter internal mockSwapRouter;
    MockQuoter internal mockQuoter;

    address internal fallbackSwapRouter;
    address internal fallbackQuoter;

    uint256 internal constant LIQUIDITY = 1_000_000 ether;

    function setUp() public virtual {
        tokenIn = new TestERC20("Token In", "TIN");
        tokenOut = new TestERC20("Token Out", "TOUT");

        mockSwapRouter = new MockSwapRouter();
        mockQuoter = new MockQuoter();
        fallbackSwapRouter = address(mockSwapRouter);
        fallbackQuoter = address(mockQuoter);

        // Pre-fund the fallback so it can deliver when it runs.
        tokenOut.mint(fallbackSwapRouter, LIQUIDITY);

        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData = abi.encodeCall(PropAMMRouter.initialize, (fallbackSwapRouter, fallbackQuoter, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(address(proxy));
    }

    /// @notice Deploys a `MockPropAMM` quoting `quote`, pre-funds it with
    /// `tokenOut`, and whitelists it on the router.
    function _deployVenue(uint256 quote) internal returns (MockPropAMM venue) {
        venue = new MockPropAMM(quote);
        tokenOut.mint(address(venue), LIQUIDITY);
        vm.prank(owner);
        router.addPropAMM(address(venue));
    }

    /// @notice Mints `amountIn` of `tokenIn` to `user` and approves the router.
    function _fundUser(uint256 amountIn) internal {
        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(router), amountIn);
    }
}
