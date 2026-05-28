// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMFeeWrapper} from "../src/PropAMMFeeWrapper.sol";

/// Run with: ETH_RPC_URL=... ROUTER_PROXY=... forge test --match-contract PropAMMFeeWrapperForkTest --fork-url $ETH_RPC_URL
contract PropAMMFeeWrapperForkTest is Test {
    function test_endToEndSwapTakesFee() public {
        try vm.envString("ETH_RPC_URL") returns (string memory) {
            address underlying = vm.envAddress("ROUTER_PROXY");
            address feeRecipient = makeAddr("feeRecipient");
            address owner = makeAddr("owner");

            PropAMMFeeWrapper impl = new PropAMMFeeWrapper();
            PropAMMFeeWrapper wrapper = PropAMMFeeWrapper(address(new ERC1967Proxy(
                address(impl),
                abi.encodeCall(PropAMMFeeWrapper.initialize, (underlying, feeRecipient, 50, owner))
            )));

            // SKELETON — flesh out at implementation time with concrete mainnet values:
            // 1. Pick a liquid pair + amount mirroring `mix gas_report` env
            //    (TOKEN_IN/TOKEN_OUT/AMOUNT_IN — see backend/lib/mix/tasks/gas_report.ex).
            // 2. `deal(tokenIn, user, AMOUNT_IN)`; vm.prank(user) approve(wrapper, AMOUNT_IN).
            // 3. vm.prank(user) wrapper.swap(Venue.FermiSwap, tokenIn, tokenOut, AMOUNT_IN, 0, user, fee, deadline).
            // 4. assertGt(IERC20(tokenOut).balanceOf(feeRecipient), 0) and assert user received the net.
            assertTrue(address(wrapper) != address(0));
        } catch {
            vm.skip(true);
        }
    }
}
