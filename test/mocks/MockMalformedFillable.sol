// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPropAMMFillable} from "../../src/interfaces/IPropAMMFillable.sol";

/// @notice A propAMM that truthfully advertises `IPropAMMFillable` via
/// ERC-165 but whose `quoteFillable` returns malformed returndata on
/// success — modeling a proxy whose implementation was swapped or unset,
/// which answers calls successfully with empty (or short) data rather than
/// reverting. Used to prove that `_probeVenue`'s decode of this venue's
/// returndata happens inside a frame the router's own `try/catch` can
/// absorb, rather than in `_probeVenue`'s own frame where it would revert
/// the whole split for every caller.
contract MockMalformedFillable is IPropAMMFillable, IERC165 {
    /// @notice When true, `quoteFillable` returns 0 bytes instead of 32.
    bool public returnEmpty;

    function setReturnEmpty(bool v) external {
        returnEmpty = v;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IPropAMMFillable).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Bypasses Solidity's normal ABI encoding for this function's
    /// declared `(uint256, uint256)` return via a raw assembly `return`, so
    /// the call succeeds with 32 bytes (or, with `returnEmpty`, 0 bytes)
    /// instead of the 64 the interface promises.
    function quoteFillable(address, address, uint256) external view returns (uint256, uint256) {
        if (returnEmpty) {
            assembly {
                return(0, 0)
            }
        }
        assembly {
            mstore(0, 7)
            return(0, 32)
        }
    }
}
