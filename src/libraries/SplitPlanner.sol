// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title SplitPlanner
/// @notice Pure planning math for `swapSplitV1`: saturation detection over
/// two-point probes, rate-ordered sorting, and pro-rata per-leg minimums.
/// @dev All amounts handled here are bounded to uint128 by the router
/// (`AmountTooLarge` on the input, candidate filtering on the outputs), which
/// keeps every cross-multiplication below 2^256.
library SplitPlanner {
    /// @notice One split candidate: `fill` of tokenIn quoted to yield `out`.
    struct Candidate {
        address venue;
        uint256 fill;
        uint256 out;
    }

    /// @notice Saturation tolerance τ in basis points. A venue is saturated
    /// iff `out(full) < 2 · out(half) · (1 − τ)`. 1% sits well above the worst
    /// in-capacity price drift measured on mainnet (22bp) and far below the
    /// saturation signal (29–50% sublinear).
    uint256 internal constant SATURATION_TOLERANCE_BPS = 100;
    uint256 internal constant BPS = 10_000;

    /// @notice How many halvings the router may spend looking for a size a
    /// saturated venue actually fills. Two equal probe points mean the venue is
    /// saturated at BOTH, so capacity is below the half point and neither point
    /// is a usable leg size. Halving starts at the half point, so eight steps
    /// reach p/512 — enough to locate a ~4k venue inside a 1M order. Past that
    /// the router declines the venue rather than hand it input it will not fill.
    uint256 internal constant MAX_SATURATION_STEPS = 8;

    /// @notice True when a full-size quote is sublinear versus the half-size
    /// quote beyond τ — the venue's output has hit its inventory ceiling.
    /// @dev Equality satisfies this but says something stronger: the venue is
    /// saturated at the HALF point too, so the half point is not a usable leg
    /// size either. The router separates that case out and probes further down.
    function isSaturated(uint256 outFull, uint256 outHalf) internal pure returns (bool) {
        return outFull * BPS < 2 * outHalf * (BPS - SATURATION_TOLERANCE_BPS);
    }

    /// @notice Rate ordering: `a` beats `b` iff rate(a) > rate(b), with ties
    /// broken toward the larger fill (fewer legs when `MAX_LEGS` binds).
    /// @dev Cross-multiplied to avoid division rounding:
    /// rate(a) > rate(b) ⇔ a.out · b.fill > b.out · a.fill.
    function betterThan(Candidate memory a, Candidate memory b) internal pure returns (bool) {
        uint256 lhs = a.out * b.fill;
        uint256 rhs = b.out * a.fill;
        if (lhs != rhs) return lhs > rhs;
        return a.fill > b.fill;
    }

    /// @notice In-place insertion sort, descending by `betterThan`. N ≤ 12.
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
    /// RANKING quote.
    /// @dev Never re-quoted at the final leg size — a fresh quote is a price an
    /// adversarial venue picks after it has already won the ranking. For any
    /// venue with a consistent linear price this is provably ≤ the venue's own
    /// floored delivery, so it never trips on rounding.
    function proRataMin(uint256 out, uint256 fill, uint256 leg) internal pure returns (uint256) {
        if (leg == fill) return out;
        return out * leg / fill;
    }
}
