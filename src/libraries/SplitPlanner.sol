// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title SplitPlanner
/// @notice Pure planning math for `swapSplitV1`: saturation detection over
/// two-point probes, rate-ordered sorting, and pro-rata per-leg minimums.
/// All amounts handled here are bounded to uint128 by the router
/// (`AmountTooLarge` / candidate filtering), which keeps every
/// cross-multiplication below 2^256.
library SplitPlanner {
    /// @notice One split candidate: `fill` of tokenIn quoted to yield `out`.
    struct Candidate {
        address venue;
        uint256 fill;
        uint256 out;
    }

    /// @notice Saturation tolerance τ in basis points. A venue is saturated
    /// iff `out(full) < 2 · out(half) · (1 − τ)`. 1% sits well above the
    /// worst in-cap price drift measured in Phase 0 (22bp) and far below the
    /// saturation signal (29–50% sublinear).
    uint256 internal constant SATURATION_TOLERANCE_BPS = 100;
    uint256 internal constant BPS = 10_000;

    /// @notice How many extra halvings the router may spend looking for a
    /// probe size a saturated venue actually fills. Two equal probe points
    /// mean the venue is saturated at BOTH, so its capacity is somewhere
    /// below the half point and neither point can be used as a leg size.
    /// Halving starts at the half point, so four steps reach p/32 of the
    /// probe size; past that the router declines the venue rather than spend
    /// more gas or hand it input it will not fill. Worst case for a whole
    /// split is MAX_SPLIT_VENUES * (2 + MAX_SATURATION_STEPS) quotes, and
    /// only when every venue is saturated at both of its first two points.
    uint256 internal constant MAX_SATURATION_STEPS = 4;

    /// @notice True when a full-size quote is sublinear vs the half-size
    /// quote beyond τ — the venue's output has hit its inventory ceiling.
    /// @dev Equality (`outFull == outHalf`) satisfies this, but says something
    /// stronger: the venue is saturated at the HALF point too, so the half
    /// point is not a usable leg size either. The router separates that case
    /// out and probes further down — see `_probeDownToFillable`.
    function isSaturated(uint256 outFull, uint256 outHalf) internal pure returns (bool) {
        return outFull * BPS < 2 * outHalf * (BPS - SATURATION_TOLERANCE_BPS);
    }

    /// @notice Rate ordering: `a` beats `b` iff rate(a) > rate(b), with ties
    /// broken toward the larger fill (fewer legs when `maxLegs` binds).
    /// @dev Cross-multiplied to avoid division rounding: rate(a) > rate(b)
    /// ⇔ a.out · b.fill > b.out · a.fill.
    function betterThan(Candidate memory a, Candidate memory b) internal pure returns (bool) {
        uint256 lhs = a.out * b.fill;
        uint256 rhs = b.out * a.fill;
        if (lhs != rhs) return lhs > rhs;
        return a.fill > b.fill;
    }

    /// @notice In-place insertion sort, descending by `betterThan`. N ≤ 8.
    function sortByRateDesc(Candidate[] memory c) internal pure {
        for (uint256 i = 1; i < c.length; i++) {
            Candidate memory key = c[i];
            uint256 j = i;
            while (j > 0 && betterThan(key, c[j - 1])) {
                c[j] = c[j - 1];
                j--;
            }
            c[j] = key;
        }
    }

    /// @notice The per-leg minimum for a leg of size `leg` carved from a
    /// candidate quoted `(fill → out)`: the floored pro-rata share of the
    /// RANKING quote. For any venue with a consistent linear price this is
    /// provably ≤ the venue's own floored delivery (never trips on
    /// rounding); it is never re-quoted (a fresh quote is a price an
    /// adversarial venue picks after winning the ranking).
    function proRataMin(uint256 out, uint256 fill, uint256 leg) internal pure returns (uint256) {
        if (leg == fill) return out;
        return out * leg / fill;
    }
}
