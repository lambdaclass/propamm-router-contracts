// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that burns `transferFeeBps` of every non-mint/non-burn transfer,
/// so recipients receive less than `value`.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public immutable transferFeeBps;

    constructor(string memory name_, string memory symbol_, uint256 transferFeeBps_)
        ERC20(name_, symbol_)
    {
        transferFeeBps = transferFeeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && transferFeeBps > 0) {
            uint256 fee = value * transferFeeBps / 10_000;
            super._update(from, address(0xdEaD), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
