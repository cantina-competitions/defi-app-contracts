// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    DefiAppHomeCenterStorage,
    EpochStates,
    EpochParams,
    EpochDistributorStorage,
    MerkleUserDistroInput,
    StakingParams,
    UserConfig
} from "./libraries/DefiAppDataTypes.sol";
import {EpochDistributor} from "./libraries/EpochDistributor.sol";
import {StakeHelper} from "./libraries/StakeHelper.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDefiAppPoolHelper} from "./interfaces/IDefiAppPoolHelper.sol";
import {IAggregatorV3} from "./interfaces/chainlink/IAggregatorV3.sol";
import {UAccessControlUpgradeable} from "./dependencies/UAccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title DefiAppHomeCenter Contract
/// @author security@defi.app
contract DefiAppHomeCenter is UAccessControlUpgradeable, UUPSUpgradeable {
    using SafeCast for uint256;
    using EpochDistributor for EpochDistributorStorage;

    /// Events
    event SetDefaultRps(uint256 indexed effectiveEpoch, uint256 rps);
    event SetDefaultEpochDuration(uint256 indexed effectiveEpoch, uint32 epochDuration);
    event SetVoting(uint256 indexed effectiveEpoch, bool votingActive);
    event SetMintingActive(bool mintingActive);
    event SetPoolHelper(address poolHelper);
    event EpochInstantiated(
        uint256 indexed epoch, uint256 endBlock, uint96 estimatedStartTimestamp, uint128 estimatedDistribution
    );
    event EpochFinalized(uint256 indexed epoch);
    event StakerRegistered(address indexed user);
    event Claimed(uint256 indexed epoch, address indexed owner, address indexed receiver, uint256 tokens);

    /// Custom Errors
    error DefiAppHomeCenter_zeroAddressInput();
    error DefiAppHomeCenter_zeroValueInput();
    error DefiAppHomeCenter_notWeth9();
    error DefiAppHomeCenter_noChange();
    error DefiAppHomeCenter_invalidArrayLenghts();
    error DefiAppHomeCenter_onlyAdmin();
    error DefiAppHomeCenter_notStaker();
    error DefiAppHomeCenter_invalidEpochDuration();
    error DefiAppHomeCenter_invalidStartTimestamp();
    error DefiAppHomeCenter_invalidEndBlock();
    error DefiAppHomeCenter_invalidEpoch(uint256 epoch);
    error DefiAppHomeCenter_invalidEpochState();

    /// Constants
    uint256 public constant BLOCK_CADENCE = 2; // seconds per block
    uint256 public constant NEXT_EPOCH_BLOCKS_PREFACE = 7 days / BLOCK_CADENCE; // blocks before next epoch can be instantiated
    uint256 public constant PRECISION = 1e18; // precision for rate per second

    /// State Variables
    // keccak256(abi.encodePacked("DefiAppHomeCenter"))
    bytes32 private constant DefiAppHomeCenterStorageLocation =
        0x3d408693d2626960862af4d27394da9c222ee4ed12c70a12350875430c40459a;
    // keccak256(abi.encodePacked("EpochDistributor"))
    bytes32 private constant EpochDistributorStorageLocation =
        0x5adc47f138f163cc2f72818e1462074cc075124a849d01a5dd68e6f9e97229bc;

    function _getDefiAppHomeCenterStorage() private pure returns (DefiAppHomeCenterStorage storage $) {
        assembly {
            $.slot := DefiAppHomeCenterStorageLocation
        }
    }

    function _getEpochDistributorStorage() private pure returns (EpochDistributorStorage storage $) {
        assembly {
            $.slot := EpochDistributorStorageLocation
        }
    }

    modifier onlyStaker() {
        require(msg.sender == _getDefiAppHomeCenterStorage().stakingAddress, DefiAppHomeCenter_notStaker());
        _;
    }

    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        require(msg.sender == IDefiAppPoolHelper($.poolHelper).weth9(), DefiAppHomeCenter_notWeth9());
    }

    function initialize(address _homeToken, address _stakingAddress, uint128 _initRps, uint32 _initEpochDuration)
        public
        initializer
    {
        _setDefaultRps(_initRps);
        _setDefaultEpochDuration(_initEpochDuration);
        _checkZeroAddress(_homeToken);
        _checkZeroAddress(_stakingAddress);
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        $.homeToken = _homeToken;
        $.stakingAddress = _stakingAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// View methods
    function homeToken() external view returns (address) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.homeToken;
    }

    function stakingAddress() external view returns (address) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.stakingAddress;
    }

    function poolHelper() external view returns (address) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.poolHelper;
    }

    function getDefaultRps() external view returns (uint128) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.defaultRps;
    }

    function getDefaultEpochDuration() external view returns (uint32) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.defaultEpochDuration;
    }

    function getCurrentEpoch() external view returns (uint96) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.currentEpoch;
    }

    function getEpochParams(uint256 epoch) public view returns (EpochParams memory params) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        params = $.epochs[epoch];
        if (params.state == uint8(EpochStates.Distributed) || params.state == uint8(EpochStates.Undefined)) {
            return params;
        } else if (block.number >= params.endBlock) {
            params.state = uint8(EpochStates.Finalized);
        } else if (block.number < params.endBlock && block.timestamp >= params.startTimestamp) {
            params.state = uint8(EpochStates.Ongoing);
        }
    }

    function isVotingLive() external view returns (bool) {
        return _getDefiAppHomeCenterStorage().votingActive == 1;
    }

    function isMiningActive() external view returns (bool) {
        return _getDefiAppHomeCenterStorage().mintingActive == 1;
    }

    /// EpochDistributor view methods

    function getUserConfig(address user) external view returns (UserConfig memory) {
        return _getEpochDistributorStorage().userConfigs[user];
    }

    function getBalanceMerkleRoot(uint256 epoch) external view returns (bytes32) {
        return _getEpochDistributorStorage().balanceMerkleRoots[epoch];
    }

    function getDistributionMerkleRoot(uint256 epoch) external view returns (bytes32) {
        return _getEpochDistributorStorage().distributionMerkleRoots[epoch];
    }

    function isClaimed(uint256 epoch, address user) external view returns (bool) {
        return _getEpochDistributorStorage().isClaimed[epoch][user];
    }

    /// Permissioned setters
    function setDefaultRps(uint128 _rps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRps(_rps);
    }

    function setDefaultEpochDuration(uint32 _epochDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultEpochDuration(_epochDuration);
    }

    function setVoting(bool _votingActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        $.votingActive = _votingActive ? 1 : 0;
        emit SetVoting(_getNextEpoch($), _votingActive);
    }

    function setMintingActive(bool _mintingActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _getDefiAppHomeCenterStorage().mintingActive = _mintingActive ? 1 : 0;
        emit SetMintingActive(_mintingActive);
    }

    function callHookRegisterStaker(address user) external onlyStaker {
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        UserConfig storage userConfig = $e.userConfigs[user];
        if (userConfig.receiver == address(0)) {
            userConfig.receiver = user;
            emit StakerRegistered(user);
        }
    }

    /// Core functions

    function claim(
        uint256 epoch,
        MerkleUserDistroInput memory distro,
        bytes32[] calldata distroProof,
        StakingParams memory staking
    ) public payable {
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        if (_shouldInitializeNextEpoch($)) initializeNextEpoch();
        require(epoch < $.currentEpoch, DefiAppHomeCenter_invalidEpoch(epoch));
        $e.claimLogic($, epoch, distro, distroProof);
        if (staking.weth9ToStake > 0) {
            // Checks done in stakeClaimedLogic
            StakeHelper.stakeClaimedLogic($, msg.sender, distro.tokens, staking);
        }
    }

    function claimMulti(
        uint256[] calldata epochs,
        MerkleUserDistroInput[] memory distros,
        bytes32[][] calldata proofs,
        StakingParams memory staking
    ) public payable {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        uint256 len = epochs.length;
        require(len == distros.length && len == proofs.length, DefiAppHomeCenter_invalidArrayLenghts());
        uint256 claimed;
        for (uint256 i = 0; i < len; i++) {
            require(epochs[i] < $.currentEpoch, DefiAppHomeCenter_invalidEpoch(epochs[i]));
            $e.claimLogic($, epochs[i], distros[i], proofs[i]);
            claimed += distros[i].tokens;
        }
        if (staking.weth9ToStake > 0) {
            // Checks done in stakeClaimedLogic
            StakeHelper.stakeClaimedLogic($, msg.sender, claimed, staking);
        }
    }

    function initializeNextEpoch() public returns (bool) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        if ($.currentEpoch == 0) {
            require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), DefiAppHomeCenter_onlyAdmin());
            $.currentEpoch = _getNextEpoch($);
            _setEpochParams(
                $,
                $.currentEpoch,
                block.number + ($.defaultEpochDuration / BLOCK_CADENCE),
                block.timestamp.toUint96(),
                EpochDistributor.estimateDistributionAmount(
                    $.defaultRps, block.number, block.number + ($.defaultEpochDuration / BLOCK_CADENCE), BLOCK_CADENCE
                ).toUint128(),
                uint8(EpochStates.Ongoing)
            );
            return true;
        }
        if (block.number >= ($.epochs[$.currentEpoch].endBlock - NEXT_EPOCH_BLOCKS_PREFACE)) {
            EpochParams memory previous = $.epochs[$.currentEpoch];
            uint8 stateToSet = block.number > previous.endBlock
                ? uint8(EpochStates.Ongoing)
                : $.votingActive == 1 ? uint8(EpochStates.Voting) : uint8(EpochStates.Initialized);
            $.currentEpoch = _getNextEpoch($);
            uint256 nextEndBlock = previous.endBlock + ($.defaultEpochDuration / BLOCK_CADENCE);
            uint96 nextEstimatedStartTimestamp =
                ((nextEndBlock - block.number) * BLOCK_CADENCE + block.timestamp).toUint96();
            _setEpochParams(
                $,
                $.currentEpoch,
                nextEndBlock,
                nextEstimatedStartTimestamp,
                EpochDistributor.estimateDistributionAmount(
                    $.defaultRps, previous.endBlock, nextEndBlock, BLOCK_CADENCE
                ).toUint128(),
                stateToSet
            );
            return true;
        } else {
            return false;
        }
    }

    function settleEpoch(
        uint256 epoch,
        bytes32 balanceRoot,
        bytes32 distributioRoot,
        bytes32[] calldata balanceVerifierProofs,
        bytes32[] calldata distributionVerifierProofs
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        EpochStates state = EpochStates(getEpochParams(epoch).state);
        require(state == EpochStates.Finalized, DefiAppHomeCenter_invalidEpochState());
        _getEpochDistributorStorage().settleEpochLogic(
            $, epoch, balanceRoot, distributioRoot, balanceVerifierProofs, distributionVerifierProofs
        );
    }

    /// Internal functions
    function _getNextEpoch(DefiAppHomeCenterStorage storage $) internal view returns (uint96) {
        return $.currentEpoch + 1;
    }

    function _setEpochParams(
        DefiAppHomeCenterStorage storage $,
        uint96 epochToIntantiate,
        uint256 endBlock,
        uint96 estimatedStartTimestamp,
        uint128 estimatedDistribution,
        uint8 state
    ) internal {
        require(estimatedStartTimestamp >= block.timestamp, DefiAppHomeCenter_invalidStartTimestamp());
        require(endBlock > block.number + NEXT_EPOCH_BLOCKS_PREFACE, DefiAppHomeCenter_invalidEndBlock());
        $.epochs[epochToIntantiate] = EpochParams({
            endBlock: endBlock,
            startTimestamp: estimatedStartTimestamp,
            toBeDistributed: estimatedDistribution,
            state: state
        });
        emit EpochInstantiated(epochToIntantiate, endBlock, estimatedStartTimestamp, estimatedDistribution);
    }

    function _shouldInitializeNextEpoch(DefiAppHomeCenterStorage storage $) internal view returns (bool) {
        return block.number >= ($.epochs[$.currentEpoch].endBlock - NEXT_EPOCH_BLOCKS_PREFACE);
    }

    function _setDefaultRps(uint128 _rps) internal {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        require(_rps > 0, DefiAppHomeCenter_zeroValueInput());
        require(_rps != $.defaultRps, DefiAppHomeCenter_noChange());
        $.defaultRps = _rps;
        emit SetDefaultRps(_getNextEpoch($), _rps);
    }

    function _setDefaultEpochDuration(uint32 _epochDuration) internal {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        require(_epochDuration > 0, DefiAppHomeCenter_zeroValueInput());
        require(_epochDuration != $.defaultEpochDuration, DefiAppHomeCenter_noChange());
        require(_epochDuration > NEXT_EPOCH_BLOCKS_PREFACE, DefiAppHomeCenter_invalidEpochDuration());
        $.defaultEpochDuration = _epochDuration;
        emit SetDefaultEpochDuration(_getNextEpoch($), _epochDuration);
    }

    function _checkZeroAddress(address addr) internal pure {
        require(addr != address(0), DefiAppHomeCenter_zeroAddressInput());
    }

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}
}
