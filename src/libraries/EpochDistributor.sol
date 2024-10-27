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

    /// Constants
    address private constant _MAGIC_NUMBER = 0x403E403e403e403e403E403E403e403e403E403E;

    /// Custom Errors
    error EpochDistributor_invalidBlockRange();
    error EpochDistributor_invalidEpoch();
    error EpochDistributor_epochAlreadyDistributed();
    error EpochDistributor_balanceRootEmpty();
    error EpochDistributor_distributionRootEmpty();
    error EpochDistributor_invalidBalanceProof();
    error EpochDistributor_invalidDistroProof();
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

    /**
     * @notice Generate the merkle leaf for a user balance of type MerkleUserBalInput
     * @param input MerkleUserBalInput
     */
    function getLeaveUserBalanceMerkleTree(MerkleUserBalInput memory input) public pure returns (bytes32 leaf) {
        return
            keccak256(abi.encodePacked(input.avgBalance, input.boost, input.protocolId, input.timeSpanId, input.userId));
    }

    /**
     * @notice Generate the merkle leaf for a user distribution of type MerkleUserDistroInput
     * @param input MerkleUserDistroInput
     */
    function getLeaveUserDistroMerkleTree(MerkleUserDistroInput memory input) public pure returns (bytes32 leaf) {
        return keccak256(abi.encodePacked(input.points, input.tokens, input.userId));
    }

    /**
     * @notice Settle an epoch by setting the merkle roots that will allow users to claim their rewards
     * @param epoch epoch to settle
     * @param balanceRoot merkle root of the user balances
     * @param distributionRoot merkle root of the user distributions
     * @param balanceProof proof that includes leave of MAGIC_NUMBER for `balanceRoot`
     * @param distroProof  proof that includes leave of MAGIC_NUMBER for `distributionRoot`
     */
    function settleEpochLogic(
        EpochDistributorStorage storage $e,
        DefiAppHomeCenterStorage storage $,
        uint256 epoch,
        bytes32 balanceRoot,
        bytes32 distributionRoot,
        bytes32[] calldata balanceProof,
        bytes32[] calldata distroProof
    ) public {
        require(balanceRoot.length > 0, EpochDistributor_balanceRootEmpty());
        require(distributionRoot.length > 0, EpochDistributor_distributionRootEmpty());
        require(
            _verify(balanceProof, balanceRoot, getLeaveUserBalanceMerkleTree(_getVerifierMerkleUserBalInput())),
            EpochDistributor_invalidBalanceProof()
        );
        require(
            _verify(distroProof, distributionRoot, getLeaveUserDistroMerkleTree(_getVerifierMerkleUserDistroInput())),
            EpochDistributor_invalidDistroProof()
        );

        EpochParams storage epochParams = $.epochs[epoch];
        epochParams.state = uint8(EpochStates.Distributed);
        $e.balanceMerkleRoots[epoch] = balanceRoot;
        $e.distributionMerkleRoots[epoch] = distributionRoot;

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
        EpochDistributorStorage storage $e,
        DefiAppHomeCenterStorage storage $,
        uint256 epoch,
        MerkleUserDistroInput memory distro,
        bytes32[] calldata distroProof
    ) public {
        require($e.isClaimed[epoch][distro.userId] == false, EpochDistributor_epochAlreadyDistributed());
        require(
            !_verify(distroProof, $e.distributionMerkleRoots[epoch], getLeaveUserDistroMerkleTree(distro)),
            EpochDistributor_invalidDistroProof()
        );
        Home($.homeToken).safeTransfer($e.userConfigs[distro.userId].receiver, distro.tokens);
        $e.isClaimed[epoch][distro.userId] = true;
        // TODO: include variants that re-stake the tokens
    }

    function _getVerifierMerkleUserBalInput() private pure returns (MerkleUserBalInput memory) {
        return MerkleUserBalInput({
            avgBalance: uint256(uint160(_MAGIC_NUMBER)),
            boost: uint256(uint160(_MAGIC_NUMBER)),
            protocolId: bytes32(uint256(uint160(_MAGIC_NUMBER))),
            timeSpanId: bytes32(uint256(uint160(_MAGIC_NUMBER))),
            userId: _MAGIC_NUMBER
        });
    }

    function _getVerifierMerkleUserDistroInput() private pure returns (MerkleUserDistroInput memory) {
        return MerkleUserDistroInput({
            points: uint256(uint160(_MAGIC_NUMBER)),
            tokens: uint256(uint160(_MAGIC_NUMBER)),
            userId: _MAGIC_NUMBER
        });
    }

    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        return MerkleProof.verify(proof, root, leaf);
    }
}
