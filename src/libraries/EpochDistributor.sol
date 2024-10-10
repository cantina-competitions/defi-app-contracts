// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {DefiAppHomeCenterStorage, EpochParams, EpochStates, EpochDistributorStorage} from "./DefiAppDataTypes.sol";
import {MerkleUserBalInput, MerkleUserDistroInput} from "./DefiAppDataTypes.sol";
import {DefiAppHomeCenter} from "../DefiAppHomeCenter.sol";
import {Home} from "../token/Home.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library EpochDistributor {
    using SafeERC20 for Home;

    /// Custom Errors
    error EpochDistributor_invalidBlockRange();
    error EpochDistributor_invalidEpoch();
    error EpochDistributor_epochAlreadyDistributed();
    error EpochDistributor_balanceRootEmpty();
    error EpochDistributor_distributionRootEmpty();
    error EpochDistributor_insufficientBalanceForDistribution();

    /**
     * @notice Calculate the amount of tokens to be distributed in an epoch
     * @param rps token units (wei) per second
     * @param startBlock of period to calculate
     * @param endBlock  of period to calculate
     * @param blockCadence  in seconds (seconds per every block in the chain)
     */
    function estimateDistributionAmount(uint256 rps, uint256 startBlock, uint256 endBlock, uint256 blockCadence)
        public
        pure
        returns (uint256)
    {
        require(startBlock < endBlock, EpochDistributor_invalidBlockRange());
        return (endBlock - startBlock) * rps * blockCadence;
    }

    function makeUserId(address user, uint256 seed) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, block.prevrandao, user, seed));
    }

    function getLeaveUserBalanceMerkleTree(MerkleUserBalInput calldata input) public pure returns (bytes32 leaf) {
        return keccak256(
            abi.encodePacked(input.userId, input.protocolId, input.storedBalance, input.storedBoost, input.timeSpanId)
        );
    }

    function getLeaveUserDistroMerkleTree(MerkleUserDistroInput calldata input) public pure returns (bytes32 leaf) {
        return keccak256(abi.encodePacked(input.userId, input.earnedPoints, input.earnedTokens));
    }

    function settleEpochLogic(
        EpochDistributorStorage storage $d,
        DefiAppHomeCenterStorage storage $,
        uint256 epoch,
        bytes32 balanceRoot,
        bytes32 distributionRoot
    ) public {
        require(balanceRoot.length > 0, EpochDistributor_balanceRootEmpty());
        require(distributionRoot.length > 0, EpochDistributor_distributionRootEmpty());
        EpochParams storage epochParams = $.epochs[epoch];
        epochParams.state = uint8(EpochStates.Distributed);
        $d.balanceMerkleRoots[epoch] = balanceRoot;
        $d.distributionMerkleRoots[epoch] = distributionRoot;

        Home home = Home($.homeToken);
        if ($.mintingActive == 1) {
            home.mint(address(this), epochParams.toBeDistributed);
        } else {
            home.safeTransferFrom(msg.sender, address(this), epochParams.toBeDistributed);
        }
        require(
            home.balanceOf(address(this)) >= epochParams.toBeDistributed,
            EpochDistributor_insufficientBalanceForDistribution()
        );
        emit DefiAppHomeCenter.EpochFinalized(epoch);
    }

    function claimLogic(
        EpochDistributorStorage storage $d,
        DefiAppHomeCenterStorage storage $,
        address account,
        uint256 points,
        uint256 epoch,
        bytes32[] calldata distroProof
    ) public {
        // TODO: Implement the claimLogic function
    }
}
