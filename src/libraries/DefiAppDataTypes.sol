// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
    uint128 toBeDistributed;
    uint96 startTimestamp;
    uint8 state;
}

struct MerkleUserBalInput {
    address userId;
    bytes32 protocolId;
    uint256 storedBalance;
    uint256 storedBoost;
    bytes32 timeSpanId;
}

struct MerkleUserDistroInput {
    address userId;
    uint256 earnedPoints;
    uint256 earnedTokens;
}

struct UserConfig {
    address receiver;
    uint8 enableClaimOnBehalf;
}

struct DefiAppHomeCenterStorage {
    address homeToken;
    uint96 currentEpoch;
    address stakingAddress;
    uint96 empty_1;
    uint128 defaultRps; // defined as "ratePerSecond": as token units (wei) per second
    uint32 defaultEpochDuration; // in seconds
    uint8 votingActive; // boolean if voting is enable for next epoch
    uint8 mintingActive; // boolean if minting is used for distribution
    uint80 empty_2;
    bytes32[] activeDefiApps;
    mapping(uint256 => EpochParams) epochs;
}

struct EpochDistributorStorage {
    mapping(address => UserConfig) userConfigs;
    mapping(uint256 => bytes32) balanceMerkleRoots; // epoch => user recorded balances merkle root
    mapping(uint256 => bytes32) distributionMerkleRoots; // epoch => user distribution merkle root
    mapping(uint256 => mapping(address => bool)) isClaimed; // epoch => userId => claimed
}
