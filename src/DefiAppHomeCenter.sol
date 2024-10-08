// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    DefiAppHomeCenterStorage,
    EpochStates,
    EpochParams,
    EpochDistributorStorage
} from "./libraries/DefiAppDataTypes.sol";
import {EpochDistributor} from "./libraries/EpochDistributor.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DefiAppHomeCenter is AccessControlUpgradeable, UUPSUpgradeable {
    using SafeCast for uint256;
    using EpochDistributor for EpochDistributorStorage;

    /// Events
    event SetDefaultRps(uint256 indexed effectiveEpoch, uint32 rps);
    event SetDefaultEpochDuration(uint256 indexed effectiveEpoch, uint32 epochDuration);
    event SetVoting(uint256 indexed effectiveEpoch, bool votingActive);
    event EpochInstantiated(uint256 indexed epoch, uint256 endBlock, uint96 estimatedStartTimestamp, uint128 rps);

    /// Custom Errors
    error DefiAppHomeCenter_zeroAddressInput();
    error DefiAppHomeCenter_zeroValueInput();
    error DefiAppHomeCenter_noChange();
    error DefiAppHomeCenter_invalidArrayLenghts();
    error DefiAppHomeCenter_onlyAdmin();
    error DefiAppHomeCenter_invalidEpochDuration();
    error DefiAppHomeCenter_invalidStartTimestamp();
    error DefiAppHomeCenter_invalidEndBlock();

    /// Constants
    uint256 public constant BLOCK_CADENCE = 2; // seconds per block
    uint256 public constant NEXT_EPOCH_PREFACE = 3 days * BLOCK_CADENCE; // blocks before next epoch can be instantiated

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

    function initialize(address _homeToken, uint128 _initRps, uint32 _initEpochDuration) public initializer {
        require(_homeToken != address(0), DefiAppHomeCenter_zeroAddressInput());
        require(_initRps > 0, DefiAppHomeCenter_zeroValueInput());
        require(_initEpochDuration > 0, DefiAppHomeCenter_zeroValueInput());
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        $.homeToken = _homeToken;
        $.defaultRps = _initRps;
        $.defaultEpochDuration = _initEpochDuration;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// View methods
    function homeToken() external view returns (address) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.homeToken;
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

    function getEpochParams(uint256 epoch) external view returns (EpochParams memory params) {
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

    function isVotingMechanicsLive() external view returns (bool) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        return $.votingActive == 1;
    }

    /// Admin setters
    function setDefaultRps(uint32 _rps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        require(_rps != $.defaultRps, DefiAppHomeCenter_noChange());
        $.defaultRps = _rps;
        emit SetDefaultRps(_getNextEpoch($), _rps);
    }

    function setDefaultEpochDuration(uint32 _epochDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        require(_epochDuration != $.defaultEpochDuration, DefiAppHomeCenter_noChange());
        require(_epochDuration > NEXT_EPOCH_PREFACE, DefiAppHomeCenter_invalidEpochDuration());
        $.defaultEpochDuration = _epochDuration;
        emit SetDefaultEpochDuration(_getNextEpoch($), _epochDuration);
    }

    function setVoting(bool _votingActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        $.votingActive = _votingActive ? 1 : 0;
        emit SetVoting(_getNextEpoch($), _votingActive);
    }

    /// Core functions

    function claim(uint256 epoch, uint256 points, bytes32[] calldata distroProof) external {
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        // TODO: implement the rest of the function
        $e.claimLogic($, _msgSender(), epoch, points, distroProof);
    }

    function claimMulti(uint256[] calldata epochs, uint256[] calldata points, bytes32[][] calldata proofs) external {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        // TODO: implement the rest of the function
        uint256 len = epochs.length;
        require(len == points.length && len == proofs.length, DefiAppHomeCenter_invalidArrayLenghts());
        for (uint256 i = 0; i < len; i++) {
            $e.claimLogic($, _msgSender(), epochs[i], points[i], proofs[i]);
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
                $.defaultRps,
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
                $.defaultRps,
                stateToSet
            );
            return true;
        } else {
            return false;
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
        uint128 rps,
        uint8 state
    ) internal {
        require(estimatedStartTimestamp > block.timestamp, DefiAppHomeCenter_invalidStartTimestamp());
        require(endBlock > block.number + NEXT_EPOCH_PREFACE, DefiAppHomeCenter_invalidEndBlock());
        $.epochs[epochToIntantiate] =
            EpochParams({endBlock: endBlock, startTimestamp: estimatedStartTimestamp, rps: rps, state: state});
        emit EpochInstantiated(epochToIntantiate, endBlock, estimatedStartTimestamp, rps);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
