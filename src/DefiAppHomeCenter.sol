// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DefiAppHomeCenter is AccessControlUpgradeable, UUPSUpgradeable {
    struct EpochParams {
        uint32 epochDuration;
        uint32 startTimestamp;
        uint32 rps;
    }

    struct DefiAppHomeCenterStorage {
        address homeToken;
        uint256 currentEpoch;
        uint32 defaultRps;
        uint32 defaultEpochDuration;
        bytes32[] activeDefiApps;
        mapping(uint256 => EpochParams) epochs;
    }

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

    function _getDefiAppHomeCenterStorage() private pure returns (DefiAppHomeCenterStorage storage $) {
        assembly {
            $.slot := DefiAppHomeCenterStorageLocation
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

    /// Internal functions
    function _getNextEpoch(DefiAppHomeCenterStorage storage $) internal view returns (uint256) {
        return $.currentEpoch + 1;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
