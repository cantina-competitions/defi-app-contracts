// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

struct DefiAppHomeCenterStorage {
    address homeToken;
    uint256 currentEpoch;
    uint32 defaultRps;
    uint32 defaultEpochDuration;
    bytes32[] activeDefiApps;
    mapping(uint256 => EpochParams) epochs;
}

struct EpochParams {
    uint32 epochDuration;
    uint32 startTimestamp;
    uint32 rps;
}

struct EpochDistributorStorage {
    mapping(uint256 => bytes32) userBalancesMerkleRoots; // epoch => userBalancesMerkleRoot
    mapping(uint256 => bytes32) distributionMerkleRoots; // epoch => userBalancesMerkleRoot
    mapping(uint256 => mapping(address => bool)) isClaimed; // epoch => user => claimed
}
