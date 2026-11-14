// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Test-only. Models funds leaving a holder outright (e.g. a venue
    /// that consumes in-flight balance while quoting) — no production token
    /// path exposes a caller-triggerable burn.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
