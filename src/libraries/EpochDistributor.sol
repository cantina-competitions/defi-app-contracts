// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {DefiAppHomeCenterStorage, EpochParams, EpochDistributorStorage} from "./DefiAppDataTypes.sol";

library EpochDistributor {
    /// Custom Errors
    error DEpochDistributor_invalidEpoch();
    error EpochDistributor_epochAlreadyDistributed();

    function claimLogic(
        EpochDistributorStorage storage $e,
        DefiAppHomeCenterStorage storage $,
        address account,
        uint256 epoch,
        bytes32[] calldata proof
    ) public {
        // TODO: Implement the claimLogic function
    }
}
