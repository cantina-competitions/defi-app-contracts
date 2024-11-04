// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolHelper} from "./radiant/IPoolHelper.sol";

interface IDefiAppPoolHelper is IPoolHelper {
    function pairToken() external view returns (address);
    function weth9() external view returns (address);
}
