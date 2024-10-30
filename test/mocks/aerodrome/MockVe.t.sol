// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockToken} from "../MockToken.t.sol";

contract MockVe is MockToken {
    constructor(string memory name, string memory symbol) MockToken(name, symbol) {}

    function token() public pure returns (address) {
        return address(1024);
    }
}
