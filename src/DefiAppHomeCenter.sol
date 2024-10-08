// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DefiAppHomeCenterStorage, EpochParams, EpochDistributorStorage} from "./libraries/DefiAppDataTypes.sol";
import {EpochDistributor} from "./libraries/EpochDistributor.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DefiAppHomeCenter is AccessControlUpgradeable, UUPSUpgradeable {
    using EpochDistributor for EpochDistributorStorage;

    /// Events
    event SetDefaultRps(uint256 indexed effectiveEpoch, uint32 rps);
    event SetDefaultEpochDuration(uint256 indexed effectiveEpoch, uint32 epochDuration);

    /// Custom Errors
    error DefiAppHomeCenter_noZeroAddressInput();
    error DefiAppHomeCenter_noChange();

    /// Constants

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

    function initialize(address _homeToken) public initializer {
        require(_homeToken != address(0), DefiAppHomeCenter_noZeroAddressInput());
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        $.homeToken = _homeToken;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// Admin setters
    function setDefaultRps(uint32 _rps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        if (_rps == $.defaultRps) revert DefiAppHomeCenter_noChange();
        $.defaultRps = _rps;
        emit SetDefaultRps(_getNextEpoch($), _rps);
    }

    function setDefaultEpochDuration(uint32 _epochDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        if (_epochDuration == $.defaultEpochDuration) revert DefiAppHomeCenter_noChange();
        $.defaultEpochDuration = _epochDuration;
        emit SetDefaultEpochDuration(_getNextEpoch($), _epochDuration);
    }

    /// Core functions

    function claim(uint256 epoch, bytes32[] calldata proof) external {
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        // TODO: implement the rest of the function
        $e.claimLogic($, _msgSender(), epoch, proof);
    }

    function claimMulti(uint256[] calldata epochs, bytes32[][] calldata proofs) external {
        DefiAppHomeCenterStorage storage $ = _getDefiAppHomeCenterStorage();
        EpochDistributorStorage storage $e = _getEpochDistributorStorage();
        // TODO: implement the rest of the function
        uint256 len = epochs.length;
        for (uint256 i = 0; i < len; i++) {
            $e.claimLogic($, _msgSender(), epochs[i], proofs[i]);
        }
    }

    /// Internal functions
    function _getNextEpoch(DefiAppHomeCenterStorage storage $) internal view returns (uint256) {
        return $.currentEpoch + 1;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
