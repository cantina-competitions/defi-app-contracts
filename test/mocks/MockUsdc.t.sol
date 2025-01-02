// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockToken} from "./MockToken.t.sol";

contract MockUsdc is MockToken {
    constructor() MockToken("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
