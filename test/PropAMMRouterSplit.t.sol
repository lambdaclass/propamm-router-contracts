// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSwapRouter02} from "./mocks/MockSwapRouter02.sol";
import {MockQuoterV2} from "./mocks/MockQuoterV2.sol";
import "../src/libraries/Errors.sol";

contract PropAMMRouterSplitTest is Test {
    PropAMMRouter internal router;
    AccessManager internal manager;
    MockSwapRouter02 internal uni;
    MockQuoterV2 internal quoter;
    MockERC20 internal tin;
    MockERC20 internal tout;

    address internal owner = address(this);
    address internal user = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    function setUp() public virtual {
        uni = new MockSwapRouter02();
        quoter = new MockQuoterV2();
        tin = new MockERC20("TokenIn", "TIN");
        tout = new MockERC20("TokenOut", "TOUT");

        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory initData =
            abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(quoter), address(manager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = PropAMMRouter(payable(address(proxy)));
    }

    function test_isSplitAvailable_trueWhenWhitelistIsSmall() public view {
        assertTrue(router.isSplitAvailable());
    }

    function test_maxLegs_isFive() public view {
        assertEq(router.MAX_LEGS(), 5);
    }

    function test_maxSplitVenues_isTwelve() public view {
        assertEq(router.MAX_SPLIT_VENUES(), 12);
    }

    function test_isSplitAvailable_falsePastTheCap() public {
        for (uint160 i = 1; i <= 13; i++) {
            router.addVenue(address(i));
        }
        assertEq(router.whitelistedVenueCount(), 13);
        assertFalse(router.isSplitAvailable());
    }

    function _fund(uint256 amt) internal {
        tin.mint(user, amt);
        vm.prank(user);
        tin.approve(address(router), amt);
    }

    /// @dev With no whitelisted venues there are no candidates, so the whole
    /// order becomes one Uniswap leg. Deliberately NOT an error: it is the same
    /// outcome as a whitelist whose every venue is dead.
    function test_split_emptyWhitelistRoutesEverythingToUniswap() public {
        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 out = router.swapSplitV1(address(tin), address(tout), 1000e18, 900e18, recipient, block.timestamp + 1);

        assertEq(out, 990e18);
        assertEq(tout.balanceOf(recipient), 990e18);
    }

    function test_split_revertsPastDeadline() public {
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(Expired.selector);
        router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp - 1);
    }

    function test_split_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        router.swapSplitV1(address(tin), address(tout), 0, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsOnAmountAboveUint128() public {
        uint256 tooBig = uint256(type(uint128).max) + 1;
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AmountTooLarge.selector, tooBig));
        router.swapSplitV1(address(tin), address(tout), tooBig, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsOnIdenticalTokens() public {
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(IdenticalTokens.selector);
        router.swapSplitV1(address(tin), address(tin), 1000e18, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsOnStrayMsgValueForERC20() public {
        _fund(1000e18);
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidValue.selector, 0, 1 ether));
        router.swapSplitV1{value: 1 ether}(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
    }

    function test_split_revertsWhenAggregateBelowMin() public {
        _fund(1000e18);
        uni.setAmountOut(800e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 900e18, 800e18));
        router.swapSplitV1(address(tin), address(tout), 1000e18, 900e18, recipient, block.timestamp + 1);
    }

    function test_split_revertsPastVenueCap() public {
        for (uint160 i = 1; i <= 13; i++) {
            router.addVenue(address(i));
        }
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TooManyVenues.selector, 13));
        router.swapSplitV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1);
    }
}
