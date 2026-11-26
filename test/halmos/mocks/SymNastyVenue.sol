// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMM} from "../../../src/interfaces/IPropAMM.sol";
import {IPropAMMFillable} from "../../../src/interfaces/IPropAMMFillable.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice A hostile propAMM venue for the CUSTODY checks. On every call it
/// may:
///   - try to pull either token out of the router (`transferFrom`, which
///     only works if the router left it an allowance);
///   - push an arbitrary amount of either token INTO the router (a donation,
///     which the router tolerates by design — see `_planSplit`);
///   - quote anything, and in `swap` keep any part of what it was sent,
///     refund any part of it to the router, and deliver any amount.
/// Every amount is a fresh symbolic value, so zero ("doesn't do it") is one of
/// the cases.
/// @dev It never burns or moves router funds by any other route: a real venue
/// cannot. `MockERC20.burn` is deliberately not used.
///
/// Records, for the check's accounting, everything it moved to or from the
/// router. A call the router rolls back (a rejected leg, a reverted quote)
/// rolls these records back with the balances, so they always describe the
/// transfers that actually happened.
///
/// `fillable` makes it also advertise `IPropAMMFillable`, so one mock covers
/// both of the router's pricing paths.
contract SymNastyVenue is IPropAMM, IERC165, SymTest {
    address public immutable router;
    bool public immutable fillable;

    /// @notice Net tokens this venue pushed into the router, per token.
    mapping(address => uint256) public pushedToRouter;
    /// @notice Net tokens this venue pulled out of the router, per token.
    mapping(address => uint256) public pulledFromRouter;
    /// @notice `tokenIn` the router sent this venue in executed legs.
    uint256 public legInput;

    constructor(address router_, bool fillable_) {
        router = router_;
        fillable = fillable_;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        return id == type(IERC165).interfaceId || (fillable && id == type(IPropAMMFillable).interfaceId);
    }

    function isActive(address, address) external pure returns (bool) {
        return true;
    }

    function getPairs() external pure returns (TokenPair[] memory pairs) {
        return new TokenPair[](0);
    }

    function quote(address tokenIn, address tokenOut, uint256) external returns (uint256 out) {
        _misbehave(tokenIn, tokenOut, false);
        out = svm.createUint256("nasty.quote");
    }

    function quoteFillable(address tokenIn, address tokenOut, uint256)
        external
        returns (uint256 fillableAmountIn, uint256 amountOut)
    {
        _misbehave(tokenIn, tokenOut, false);
        fillableAmountIn = svm.createUint256("nasty.fillable");
        amountOut = svm.createUint256("nasty.fillableOut");
    }

    /// @dev The router pushes the leg's input before calling. What arrived is
    /// read from the balance, net of everything this venue already holds.
    function swap(address tokenIn, address tokenOut, uint256, uint256, address recipient, uint256)
        external
        returns (uint256 amountOut)
    {
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - _heldIn;
        legInput += received;
        _heldIn += received;

        uint256 refund = svm.createUint256("nasty.refund");
        if (refund > received) refund = received;
        _push(tokenIn, refund);
        _heldIn -= refund;

        // When the router itself is the leg's recipient (ETH out, or the fee
        // variant), `tokenOut` it receives during this swap IS delivery: the
        // router measures the leg by its own balance. Recording it as a
        // donation would double-count it.
        _misbehave(tokenIn, tokenOut, recipient == router);
        amountOut = uint128(svm.createUint256("nasty.out"));
        MockERC20(tokenOut).mint(recipient, amountOut);
    }

    /// @dev `tokenIn` this venue holds from earlier legs, so `swap` can tell
    /// what the current leg sent.
    uint256 private _heldIn;

    function _misbehave(address tokenIn, address tokenOut, bool outGiftIsDelivery) internal {
        // Pulled `tokenIn` stays here, so it counts as held: it must not be
        // mistaken for a leg's input by a later `swap`.
        //
        // One wei is enough: the pull succeeds iff the router left this venue
        // ANY allowance. A symbolic amount would fork every call on "zero vs
        // nonzero" for no extra coverage.
        _heldIn += _tryPull(tokenIn, 1);
        _tryPull(tokenOut, 1);
        // Donations are minted, not taken from this venue's balance, so they
        // never touch `_heldIn`.
        // Gifts fit in 64 bits so no mint can overflow a total supply: an
        // overflow would only revert (and fork a path for it).
        uint256 giftIn = uint64(svm.createUint256("nasty.giftIn"));
        MockERC20(tokenIn).mint(router, giftIn);
        pushedToRouter[tokenIn] += giftIn;
        uint256 giftOut = uint64(svm.createUint256("nasty.giftOut"));
        MockERC20(tokenOut).mint(router, giftOut);
        if (!outGiftIsDelivery) pushedToRouter[tokenOut] += giftOut;
    }

    function _tryPull(address token, uint256 amount) internal returns (uint256 pulled) {
        try IERC20(token).transferFrom(router, address(this), amount) returns (bool ok) {
            if (ok) pulled = amount;
        } catch {}
        pulledFromRouter[token] += pulled;
    }

    function _push(address token, uint256 amount) internal {
        IERC20(token).transfer(router, amount);
        pushedToRouter[token] += amount;
    }
}
