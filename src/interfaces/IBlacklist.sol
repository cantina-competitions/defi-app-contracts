// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBlacklist {
    function isBlacklisted(address _account) external view returns (bool);
}
