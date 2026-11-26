// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice WETH9 stand-in for the Halmos checks, `vm.etch`ed at the mainnet
/// WETH address the router hard-codes. Unlike `test/mocks/MockWETH.sol` it is
/// a `MockERC20`, so the symbolic venues and `SymUniswap` can mint it like any
/// other token.
/// @dev Minting WETH without depositing ETH breaks WETH's backing, so the
/// check gives this contract a large ETH balance: every `withdraw` the router
/// makes is then payable. That models a solvent WETH, which the real one is.
contract SymWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: ETH transfer failed");
    }
}
