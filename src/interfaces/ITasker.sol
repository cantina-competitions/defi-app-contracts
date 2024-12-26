// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITasker {
    function onTaskReceived(bytes calldata data) external;
}
