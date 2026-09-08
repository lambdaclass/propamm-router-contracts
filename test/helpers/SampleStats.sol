// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @notice Summary statistics over a partially-filled sample array.
///
/// Fork samplers allocate their result arrays at the full sample count but
/// only fill the samples that produced a measurement — a block whose venue
/// lane could not be recovered yields nothing. The untouched slots stay zero,
/// and a median taken over the whole array sorts those in as if the venue had
/// measured zero depth. Every function here therefore takes the number of
/// FILLED entries explicitly rather than reading `a.length`.
library SampleStats {
    /// @dev Median over the first `n` entries of `a`. Sorts `a` in place.
    /// `n == 0` means nothing was measured; the 0 it returns is the absence of
    /// data, and callers must report the sample count alongside it so the two
    /// cannot be confused downstream.
    function median(uint256[] memory a, uint256 n) internal pure returns (uint256) {
        if (n == 0) return 0;
        for (uint256 i = 1; i < n; i++) {
            uint256 k = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > k) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = k;
        }
        return a[n / 2];
    }
}
