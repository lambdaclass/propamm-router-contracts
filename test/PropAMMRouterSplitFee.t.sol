// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {PropAMMRouterSplitTest} from "./PropAMMRouterSplit.t.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {FrontendFees} from "../src/libraries/FrontendFees.sol";
import "../src/libraries/Errors.sol";

contract PropAMMRouterSplitFeeTest is PropAMMRouterSplitTest {
    address internal feeRecipient = address(0xFEE);

    function _fee(uint16 bps) internal view returns (IPropAMMRouter.FrontendFee memory) {
        return IPropAMMRouter.FrontendFee({bps: bps, recipient: feeRecipient});
    }

    /// @dev 100 bps of a 990 gross output is 9.9; the user nets 980.1.
    function test_splitFee_skimsFromGrossAndUserNets() public {
        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 net = router.swapSplitWithFeeV1(
            address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1, _fee(100)
        );

        assertEq(net, 980.1e18);
        assertEq(tout.balanceOf(recipient), 980.1e18);
        assertEq(tout.balanceOf(feeRecipient), 9.9e18);
    }

    /// @dev Proves `_skimAndDisburse` is checked against the RAW net
    /// `amountOutMin`, not `grossMin`. With gross delivered fixed at 990e18
    /// and a 100 bps fee, the actual net is 980.1e18. `amountOutMin = 975e18`
    /// is a net floor the actual net clears (975 <= 980.1), so the call must
    /// SUCCEED. But `grossUp(975e18, 100bps) = 984.848...e18` exceeds the
    /// actual net of 980.1e18 — so if `_skimAndDisburse` were (wrongly) passed
    /// `grossMin` instead of the raw `amountOutMin`, this exact call would
    /// spuriously revert `InsufficientOutput(grossMin, net)` even though the
    /// user's real, net-denominated floor was met. A bare `vm.expectRevert()`
    /// cannot tell these two bases apart because BOTH read as a floor
    /// violation; asserting success here is what pins the basis down.
    function test_splitFee_amountOutMinIsNet() public {
        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 net = router.swapSplitWithFeeV1(
            address(tin), address(tout), 1000e18, 975e18, recipient, block.timestamp + 1, _fee(100)
        );

        assertEq(net, 980.1e18);
        assertEq(tout.balanceOf(recipient), 980.1e18);
    }

    function test_splitFee_zeroBpsTakesNothing() public {
        _fund(1000e18);
        uni.setAmountOut(990e18);

        vm.prank(user);
        uint256 net =
            router.swapSplitWithFeeV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1, _fee(0));
        assertEq(net, 990e18);
        assertEq(tout.balanceOf(feeRecipient), 0);
    }

    function test_splitFee_revertsAboveCap() public {
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FrontendFees.FeeBpsTooHigh.selector, uint16(101), uint16(100)));
        router.swapSplitWithFeeV1(address(tin), address(tout), 1000e18, 0, recipient, block.timestamp + 1, _fee(101));
    }

    function test_splitFee_revertsOnZeroFeeRecipient() public {
        _fund(1000e18);
        vm.prank(user);
        vm.expectRevert(ZeroAddress.selector);
        router.swapSplitWithFeeV1(
            address(tin),
            address(tout),
            1000e18,
            0,
            recipient,
            block.timestamp + 1,
            IPropAMMRouter.FrontendFee({bps: 50, recipient: address(0)})
        );
    }
}
