// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IPropAMMRouter} from "../src/interfaces/IPropAMMRouter.sol";
import {PropAMMRouter} from "../src/PropAMMRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockCappedPropAMM} from "./mocks/MockCappedPropAMM.sol";
import {MockConcaveSwapRouter, MockConcaveQuoterV2} from "./mocks/MockConcaveUniswap.sol";
import "../src/libraries/Errors.sol";

/// @notice Covers `_waterfall`'s Uniswap reference cutoff against a CONCAVE
/// (constant-product) reference, which the rest of the split suite cannot
/// reach: `MockLinearQuoterV2` has a size-independent rate, so `refSize`
/// cancels out of the cutoff predicate `out * refSize <= refOut * fill` and
/// the one-shot refinement provably cannot change any outcome. See
/// {MockConcaveUniswap} for the full argument.
contract PropAMMRouterSplitReferenceTest is Test {
    PropAMMRouter router;
    AccessManager manager;
    MockConcaveSwapRouter uni;
    MockConcaveQuoterV2 quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        uni = new MockConcaveSwapRouter();
        quoter = new MockConcaveQuoterV2();
        tokenIn = new MockERC20("In", "IN");
        tokenOut = new MockERC20("Out", "OUT");
        manager = new AccessManager(owner);
        PropAMMRouter impl = new PropAMMRouter();
        bytes memory data = abi.encodeCall(PropAMMRouter.initialize, (address(uni), address(quoter), address(manager)));
        router = PropAMMRouter(payable(address(new ERC1967Proxy(address(impl), data))));
    }

    function _venue(uint256 num, uint256 den, uint256 cap) internal returns (MockCappedPropAMM v) {
        v = new MockCappedPropAMM(num, den);
        v.setCap(cap);
        v.setCapMode(MockCappedPropAMM.CapMode.Saturate);
        tokenOut.mint(address(v), 100_000_000e18);
        vm.prank(owner);
        router.addVenue(address(v));
    }

    function _fundUser(uint256 amount) internal {
        tokenIn.mint(user, amount);
        vm.prank(user);
        tokenIn.approve(address(router), amount);
    }

    function _split(address[] memory venues, uint256 amountIn, uint256 maxLegs) internal returns (uint256) {
        uint256[] memory noHints;
        vm.prank(user);
        return router.swapSplitV1(
            venues, noHints, address(tokenIn), address(tokenOut), amountIn, 0, 0, maxLegs, user, block.timestamp + 1
        );
    }

    /// @dev The refinement rescue. Reserves 1e24/1e24 and `amountIn = 400_000e18`
    /// make the reference concave enough that the two reference sizes straddle
    /// the venue's rate:
    ///   - coarse reference at `amountIn / 100 = 4_000e18` yields
    ///     1e24 * 4e21 / (1e24 + 4e21) ≈ 3_984.06e18, a unit rate of ~0.99602;
    ///   - refined reference at the true residual `400_000e18` yields
    ///     1e24 * 4e23 / (1e24 + 4e23) ≈ 285_714.28e18, a unit rate of ~0.71429.
    /// A venue priced at 0.98 is therefore CONTESTED by the coarse reference
    /// (0.98 < 0.99602) and ADMITTED by the refined one (0.98 > 0.71429). Before
    /// the refinement existed, the coarse reference alone would have sent the
    /// whole order to Uniswap at ~0.714 instead of using a 0.98 venue.
    function test_split_refinementRescuesCandidateTheCoarseReferenceContests() public {
        uni.setReserves(1e24, 1e24);
        quoter.setReserves(1e24, 1e24);

        uint256 amountIn = 400_000e18;
        // priceNum/priceDen = 100/98 -> out = in * 98 / 100
        MockCappedPropAMM v = _venue(100, 98, amountIn);
        _fundUser(amountIn);

        address[] memory venues = new address[](1);
        venues[0] = address(v);

        uint256 out = _split(venues, amountIn, 8);

        // The whole order went to the venue at 0.98, not to Uniswap at ~0.714.
        uint256 allVenue = amountIn * 98 / 100;
        assertEq(out, allVenue, "refinement should have admitted the venue for the whole order");
        assertGt(out, uni.quote(amountIn), "and it must beat routing everything through Uniswap");
        assertEq(tokenIn.balanceOf(address(router)), 0, "router retained tokenIn");
    }

    /// @dev The other side of the cutoff: a venue genuinely worse than Uniswap
    /// at the refined size must still be rejected, so the test above is pinning
    /// the refinement rather than a cutoff that admits everything. A venue at
    /// 0.50 loses to the refined reference's ~0.71429, so the whole order
    /// routes to Uniswap.
    function test_split_refinedReferenceStillRejectsGenuinelyWorseVenue() public {
        uni.setReserves(1e24, 1e24);
        quoter.setReserves(1e24, 1e24);

        uint256 amountIn = 400_000e18;
        MockCappedPropAMM v = _venue(100, 50, amountIn); // out = in * 0.50
        _fundUser(amountIn);

        address[] memory venues = new address[](1);
        venues[0] = address(v);

        uint256 out = _split(venues, amountIn, 8);

        assertEq(out, uni.quote(amountIn), "worse-than-Uniswap venue must be declined entirely");
        assertGt(out, amountIn * 50 / 100, "and Uniswap must have beaten the venue");
    }

    /// @dev Guards against "un-diluting" the explicit-fallback floor by
    /// scaling it over the merged slice. A 1_000e18 explicit Uniswap leg
    /// priced at its own honest rate (~0.999 against 1e24 reserves) plus a
    /// failed 1_000_000e18 prop leg merge into one swap. The scaled floor
    /// would be 0.999 * 1_001_000e18 ≈ 999_999e18, but the honest pool
    /// returns only ~500_250e18 for that size — the scaled floor exceeds it
    /// by ~2x and would revert a perfectly good swap. Only the UNSCALED floor
    /// is sound. A linear Uniswap mock cannot show this (its unit rate is
    /// size-independent, so scaling is exactly right there), which is why the
    /// test lives in the concave suite.
    function test_split_scaledExplicitFloorWouldRevertHonestSwaps() public {
        uni.setReserves(1e24, 1e24);
        quoter.setReserves(1e24, 1e24);

        uint256 smallIn = 1_000e18;
        uint256 bigIn = 1_000_000e18;
        uint256 honestSmall = uni.quote(smallIn);
        uint256 honestMerged = uni.quote(smallIn + bigIn);

        // The arithmetic that makes scaling unsound, pinned explicitly.
        uint256 scaled = honestSmall * (smallIn + bigIn) / smallIn;
        assertGt(scaled, honestMerged, "scaled floor must exceed the honest merged output");
        assertGt(scaled, honestMerged * 19 / 10, "and by a wide margin, not a rounding edge");

        // The unscaled floor is met by the same honest swap.
        assertGe(honestMerged, honestSmall, "unscaled floor is sound for a concave pool");

        // End to end: a prop leg that fails merges into the explicit leg's
        // swap, and the swap succeeds against the unscaled floor.
        MockCappedPropAMM prop = _venue(1, 1, 0);
        prop.setActive(false);
        _fundUser(smallIn + bigIn);

        IPropAMMRouter.Leg[] memory legs = new IPropAMMRouter.Leg[](2);
        legs[0] = IPropAMMRouter.Leg({venue: router.fallbackSwapRouter(), amountIn: smallIn, minOut: honestSmall});
        legs[1] = IPropAMMRouter.Leg({venue: address(prop), amountIn: bigIn, minOut: 0});

        vm.prank(user);
        uint256 out = router.swapMultiLegV1(legs, address(tokenIn), address(tokenOut), 0, 0, user, block.timestamp + 1);
        assertEq(out, honestMerged, "honest merged swap must not be blocked");
    }

    /// @dev With no live candidates `_waterfall` short-circuits to a single
    /// remainder leg, so it must not spend a `quoteExactInputSingle` (a full
    /// pool simulation) on a reference nothing will compare against.
    function test_split_noCandidatesTakesNoReferenceQuote() public {
        uni.setReserves(1e24, 1e24);
        quoter.setReserves(1e24, 1e24);

        uint256 amountIn = 1_000e18;
        MockCappedPropAMM dead = _venue(1, 1, 0);
        dead.setActive(false); // quote reverts -> no candidate
        _fundUser(amountIn);

        address[] memory venues = new address[](1);
        venues[0] = address(dead);

        // Count 0 asserts the quoter is never called during the whole swap.
        vm.expectCall(address(quoter), abi.encodeWithSelector(MockConcaveQuoterV2.quoteExactInputSingle.selector), 0);
        uint256 out = _split(venues, amountIn, 8);

        assertEq(out, uni.quote(amountIn), "everything routed through the single remainder leg");
    }
}
