// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title IPropAMMFillable
/// @notice Optional extension a propAMM implements to declare how much of an
/// order it will actually fill. Advertised via ERC-165.
/// @dev Without this, the router must discover a venue's capacity by probing
/// (two quotes plus a bounded downward search), which only locates capacity
/// within ~2x of the order size. A venue implementing this is priced in ONE
/// call and can compete on orders far larger than its inventory.
///
/// Deliberately NOT `view`: propAMM quoting in this system is already
/// state-mutating by necessity (Kipseli prices by simulating a real swap and
/// reverting with the output in its revert payload), and a `view` interface
/// would permanently exclude such venues. The router therefore treats this
/// call with exactly the same distrust as any other venue call, and brackets
/// it with the R1 balance invariant.
interface IPropAMMFillable {
    /// @notice How much of `amountIn` this venue will take, and what it pays.
    /// @param tokenIn The token the router is selling.
    /// @param tokenOut The token the router is buying.
    /// @param amountIn The input the router is offering.
    /// @return fillableAmountIn How much of `amountIn` the venue commits to
    /// fill. MUST be `<= amountIn`. A venue reporting more has broken this
    /// interface and the router discards it entirely rather than clamping.
    /// @return amountOut The output for EXACTLY `fillableAmountIn` — never the
    /// output for `amountIn`. Reporting the larger figure would inflate this
    /// venue's apparent rate by exactly the over-report.
    function quoteFillable(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint256 fillableAmountIn, uint256 amountOut);
}
