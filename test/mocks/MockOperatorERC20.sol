// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC20 with an ERC777-style operator hook: a registered operator
/// can move anyone's balance. Models token standards where a venue can pull
/// funds without a standing ERC20 allowance — the threat the router's R1
/// quote-phase balance invariant exists for.
contract MockOperatorERC20 is MockERC20 {
    mapping(address => bool) public operators;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_) {}

    function setOperator(address op) external {
        operators[op] = true;
    }

    function operatorTake(address from, address to, uint256 amount) external {
        require(operators[msg.sender], "not operator");
        _transfer(from, to, amount);
    }
}
