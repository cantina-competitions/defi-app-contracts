// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract FsConstants {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant LOCAL = 31_337;

    mapping(uint256 => string) internal _chainNames;

    constructor() {
        _chainNames[MAINNET_CHAIN_ID] = "mainnet";
        _chainNames[BASE_CHAIN_ID] = "base";
    }

    function getChainName(uint256 chainId) public view returns (string memory) {
        return _chainNames[chainId];
    }
}
