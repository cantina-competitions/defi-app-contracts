// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    DefiAppHomeCenterStorage,
    EpochStates,
    EpochParams,
    EpochDistributorStorage,
    MerkleUserDistroInput,
    UserConfig
} from "./libraries/DefiAppDataTypes.sol";
import {EpochDistributor} from "./libraries/EpochDistributor.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAggregatorV3} from "./interfaces/chainlink/IAggregatorV3.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title DefiAppHomeCenter Contract
/// @author security@defi.app
contract DefiAppHomeCenter is AccessControlUpgradeable, UUPSUpgradeable {
    using SafeCast for uint256;
    using EpochDistributor for EpochDistributorStorage;

    /// Events
    event SetDefaultRps(uint256 indexed effectiveEpoch, uint256 rps);
    event SetDefaultEpochDuration(uint256 indexed effectiveEpoch, uint32 epochDuration);
    event SetVoting(uint256 indexed effectiveEpoch, bool votingActive);
    event SetMintingActive(bool mintingActive);
    event EpochInstantiated(
        uint256 indexed epoch, uint256 endBlock, uint96 estimatedStartTimestamp, uint128 estimatedDistribution
    );
    event EpochFinalized(uint256 indexed epoch);
    event StakerRegistered(address indexed user);

    /// Custom Errors
    error DefiAppHomeCenter_zeroAddressInput();
    error DefiAppHomeCenter_zeroValueInput();
    error DefiAppHomeCenter_noChange();
    error DefiAppHomeCenter_invalidArrayLenghts();
    error DefiAppHomeCenter_onlyAdmin();
    error DefiAppHomeCenter_invalidEpochDuration();
    error DefiAppHomeCenter_invalidStartTimestamp();
    error DefiAppHomeCenter_invalidEndBlock();
    error DefiAppHomeCenter_invalidEpoch();

    /// Constants
    uint256 public constant BLOCK_CADENCE = 2; // seconds per block
    uint256 public constant NEXT_EPOCH_PREFACE = 7 days * BLOCK_CADENCE; // blocks before next epoch can be instantiated
    uint256 public constant PRECISION = 1e18; // precision for rate per second
    bytes32 public constant STAKE_ADDRESS_ROLE = keccak256("STAKE_ADDRESS_ROLE");

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

    constructor() {
        _disableInitializers();
    }

    function initialize(address _homeToken, address _stakingAddress, uint128 _initRps, uint32 _initEpochDuration)
        public
        initializer
    {
        _setDefaultRps(_initRps);
        _setDefaultEpochDuration(_initEpochDuration);
        require(_homeToken != address(0), DefiAppHomeCenter_zeroAddressInput());
        require(_stakingAddress != address(0), DefiAppHomeCenter_zeroAddressInput());
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        $.homeToken = _homeToken;
        $.stakingAddress = _stakingAddress;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(STAKE_ADDRESS_ROLE, _stakingAddress);
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

    /// Admin setters
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

    function registerStaker(address user) external onlyRole(STAKE_ADDRESS_ROLE) {
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        UserConfig storage userConfig = $e.userConfigs[user];
        if (userConfig.receiver == address(0)) {
            userConfig.receiver = user;
            emit StakerRegistered(user);
        }
    }

    /// Core functions

    function claim(uint256 epoch, MerkleUserDistroInput memory distro, bytes32[] calldata distroProof) external {
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        require(epoch < $.currentEpoch, DefiAppHomeCenter_invalidEpoch());
        $e.claimLogic($, epoch, distro, distroProof);
    }

    function claimMulti(uint256[] calldata epochs, MerkleUserDistroInput[] memory distros, bytes32[][] calldata proofs)
        external
    {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        // TODO: implement the rest of the function
        uint256 len = epochs.length;
        require(len == distros.length, DefiAppHomeCenter_invalidArrayLenghts());
        for (uint256 i = 0; i < len; i++) {
            $e.claimLogic($, epochs[i], distros[i], proofs[i]);
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
        if (block.number >= ($.epochs[$.currentEpoch].endBlock - NEXT_EPOCH_PREFACE)) {
            uint8 stateToSet = $.votingActive == 1 ? uint8(EpochStates.Voting) : uint8(EpochStates.Initialized);
            EpochParams memory previous = $.epochs[$.currentEpoch];
            $.currentEpoch = _getNextEpoch($);
            uint256 nextEndBlock = previous.endBlock + ($.defaultEpochDuration / BLOCK_CADENCE);
            uint96 nextEstimatedStartTimestamp =
                ((nextEndBlock - block.number) * BLOCK_CADENCE + block.timestamp).toUint96();
            _setEpochParams(
                $,
                $.currentEpoch,
                previous.endBlock + ($.defaultEpochDuration / BLOCK_CADENCE),
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
        if (state == EpochStates.Finalized) {
            _getEpochDistributorStorage().settleEpochLogic(
                $, epoch, balanceRoot, distributioRoot, balanceVerifierProofs, distributionVerifierProofs
            );
        }
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
        require(estimatedStartTimestamp > block.timestamp, DefiAppHomeCenter_invalidStartTimestamp());
        require(endBlock > block.number + NEXT_EPOCH_PREFACE, DefiAppHomeCenter_invalidEndBlock());
        $.epochs[epochToIntantiate] = EpochParams({
            endBlock: endBlock,
            startTimestamp: estimatedStartTimestamp,
            toBeDistributed: estimatedDistribution,
            state: state
        });
        emit EpochInstantiated(epochToIntantiate, endBlock, estimatedStartTimestamp, estimatedDistribution);
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
        require(_epochDuration > NEXT_EPOCH_PREFACE, DefiAppHomeCenter_invalidEpochDuration());
        $.defaultEpochDuration = _epochDuration;
        emit SetDefaultEpochDuration(_getNextEpoch($), _epochDuration);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
