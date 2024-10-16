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
    uint256 avgBalance; // Usd value amount expressed in integer one-dollar-units rounded to the nearest
    uint256 boost; // integer boost factor of `protocolId` in `this` epoch
    bytes32 protocolId; // unique identifier of the protocol
    bytes32 timeSpanId; // unique identifier of the time span
    address userId; // unique identifier of the user
}

struct MerkleUserDistroInput {
    uint256 points; // earned points expressed as integer rounded to nearest
    uint256 tokens; // earned tokens expressed in token units (wei or equivalent)
    address userId; // unique identifier of the user
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
