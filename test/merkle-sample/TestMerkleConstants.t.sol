// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MerkleUserDistroInput} from "../../src/DefiAppHomeCenter.sol";

contract TestMerkleConstants {
    /// Merkle roots and proofs for testing
    bytes32 public balanceRoot;
    bytes32[] public balanceMagicProof;
    bytes32 public distributionRoot;
    bytes32[] public distributionMagicProof;

    bytes32[] public user1DistroProof;
    bytes32[] public user2DistroProof;

    /// Amounts
    MerkleUserDistroInput public user1DistroInput;
    MerkleUserDistroInput public user2DistroInput;
    MerkleUserDistroInput public user3DistroInput;

    uint256 private constant USER1_AMOUNT_TO_RECEIVE = 252878048780487820000000; // from file `test/merkle-sample/distro-inputs.json`
    uint256 private constant USER2_AMOUNT_TO_RECEIVE = 1706926829268292800000000; // from file `test/merkle-sample/distro-inputs.json`
    uint256 private constant USER3_AMOUNT_TO_RECEIVE = 632195121951219500000000; // from file `test/merkle-sample/distro-inputs.json`

    constructor() {
        /// @notice The roots below are obtained from tests and data used in `test/merkle-sample/merklefunctions.test.ts`
        /// To get this values set `const DEBUG = true;` and run with:
        /// $`bun test test/merkle-sample/merklefunctions.test.ts`
        balanceRoot = 0xcc1138a7a86c3d9bfd34f64b8e57c7de8ed1911392831f8dcd60438c90b491a7;
        distributionRoot = 0x13fdc0b471ab3b57e0ad0cc44d92082dc00db9802b0370b634b1eb3395a07dd3;

        /// Refer to comment above about `Merkle roots and proofs for testing`
        balanceMagicProof = new bytes32[](2);
        balanceMagicProof[0] = 0x68eff8bdb05c9df1554ae8bc031b7e51904f0e39512d69802abf31f9b8f40f08;
        balanceMagicProof[1] = 0xaf7d40f3762de0f03633aa1a43787eb9d6ed84e94456e546aded7eb641349c0c;
        distributionMagicProof = new bytes32[](2);
        distributionMagicProof[0] = 0x8312d52780de7b98b53f615ee6bc0afee9ec61ce8a3186e94467f93f26a9cf31;
        distributionMagicProof[1] = 0xd88860eaeb04444381638dd77d248ec9f1c6a370e0300c99cce64ce794c33923;
        user1DistroProof = new bytes32[](2);
        user1DistroProof[0] = 0xd88860eaeb04444381638dd77d248ec9f1c6a370e0300c99cce64ce794c33923;
        user1DistroProof[1] = 0x747baafa08aaf243810ebcd7b5cc763efe4e63fb04f8f0a558f593ca09acd724;
        user2DistroProof = new bytes32[](2);
        user2DistroProof[0] = 0x1b3aa52159b1afa247fce4722ac38cbd20dfbde045632c7f979c264fba318061;
        user2DistroProof[1] = 0xe311d0c8e006b1841c71da16149c54a812100d6907d09c63952a6e870fdc1a9c;

        user1DistroInput = MerkleUserDistroInput({
            points: 10000, // from file `test/merkle-sample/distro-inputs.json`
            tokens: USER1_AMOUNT_TO_RECEIVE,
            userId: 0xdd845642a112D7cBd82EFE83619EB39f0894521B // from file `test/merkle-sample/distro-inputs.json`
        });

        user2DistroInput = MerkleUserDistroInput({
            points: 67500, // from file `test/merkle-sample/distro-inputs.json`
            tokens: USER2_AMOUNT_TO_RECEIVE,
            userId: 0xf30B6147971ec7F782F0704aF06881B0790b2529 // from file `test/merkle-sample/distro-inputs.json`
        });

        user3DistroInput = MerkleUserDistroInput({
            points: 25000, // from file `test/merkle-sample/distro-inputs.json`
            tokens: USER3_AMOUNT_TO_RECEIVE,
            userId: 0x390b4E9f266270a2E489dd02E32cB4F3093303b4 // from file `test/merkle-sample/distro-inputs.json`
        });
    }
}
