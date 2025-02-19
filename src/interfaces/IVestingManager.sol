// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct VestParams {
    address recipient;
    uint32 start;
    uint32 cliffDuration;
    uint32 stepDuration;
    uint32 steps;
    uint128 stepPercentage;
    uint128 amount;
    string tokenURI;
}

struct Vest {
    address owner;
    uint32 start;
    uint32 cliffDuration;
    uint32 stepDuration;
    uint32 steps;
    uint128 cliffShares;
    uint128 stepShares;
    uint128 claimed;
    string tokenURI;
}

interface IVestingManager {
    function vestingAsset() external view returns (address);

    function createVesting(VestParams calldata vestParams)
        external
        returns (uint256 depositedShares, uint256 vestId, uint128 stepShares, uint128 cliffShares);

    function withdraw(uint256 vestId) external;

    function stopVesting(uint256 vestId) external;

    function vestBalance(uint256 vestId) external view returns (uint256);

    function updateOwner(uint256 vestId, address newOwner) external;

    function setVestTokenURI(uint256 vestId, string calldata _tokenURI) external;

    event CreateVesting(
        uint256 indexed vestId,
        IERC20 token,
        address indexed owner,
        address indexed recipient,
        uint32 start,
        uint32 cliffDuration,
        uint32 stepDuration,
        uint32 steps,
        uint128 cliffShares,
        uint128 stepShares
    );

    event Withdraw(uint256 indexed vestId, IERC20 indexed token, uint256 indexed amount);

    event CancelVesting(
        uint256 indexed vestId, uint256 indexed ownerAmount, uint256 indexed recipientAmount, IERC20 token
    );

    event LogUpdateOwner(uint256 indexed vestId, address indexed newOwner);
}
