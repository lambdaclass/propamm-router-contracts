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
}
