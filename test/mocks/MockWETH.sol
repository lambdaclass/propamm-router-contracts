// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH9 stand-in for unit tests. Implements the `IWETH`
/// deposit/withdraw surface on top of a standard ERC20 so it can be `vm.etch`ed
/// at the canonical mainnet WETH address the router hard-codes in `Constants.sol`.
/// @dev When etched, the constructor does not run, so `name`/`symbol` storage is
/// left empty — harmless, the tests never read them. Balances, allowances, and
/// totalSupply all start at zero and behave normally from there.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WETH: ETH transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
