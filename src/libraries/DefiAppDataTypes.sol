// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

struct DefiAppHomeCenterStorage {
    address homeToken;
    uint96 currentEpoch;
    uint8 votingActive;
    uint32 defaultEpochDuration; // in seconds
    uint128 defaultRps; // defined as "ratePerSecond": as token units (wei) per second
    bytes32[] activeDefiApps;
    mapping(uint256 => EpochParams) epochs;
}

enum EpochStates {
    Undefined,
    Initialized,
    Voting,
    Ongoing,
    Finalized,
    Distributed
}

struct EpochParams {
    uint256 endBlock;
    uint128 rps;
    uint96 startTimestamp;
    uint8 state;
}

struct EpochDistributorStorage {
    mapping(uint256 => bytes32) balanceMerkleRoots; // epoch => user recorded balances merkle root
    mapping(uint256 => bytes32) distributionMerkleRoots; // epoch => user distribution merkle root
    mapping(uint256 => mapping(address => bool)) isClaimed; // epoch => user => claimed
}
