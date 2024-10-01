// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableToken is IERC20 {
    function mint(address _receiver, uint256 _amount) external returns (bool);

    function burn(uint256 _amount) external returns (bool);

    function setMinter(address _minter) external returns (bool);
}
