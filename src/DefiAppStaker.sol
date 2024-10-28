// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MFDBase, MFDBaseInitializerParams} from "./dependencies/MultiFeeDistribution/MFDBase.sol";
import {DefiAppHomeCenter} from "./DefiAppHomeCenter.sol";

struct DefiAppStakerStorage {
    DefiAppHomeCenter homeCenter;
}

/// @title DefiAppStaker Contract
/// @author security@defi.app
contract DefiAppStaker is MFDBase {
    /// Events
    event HomeCenterSet(address homeCenter);

    /// Custom Errors
    error DefiAppStaker_HomeCenterNotSet();

    /// State Variables
    bytes32 private constant DefiAppStakerStorageLocation =
    // keccak256(abi.encodePacked("DefiAppStaker"))
     0xbf6c9ca56d4e3846234b5cc22fe483294cf987f3e987d918b316566d7c3327ba;

    function _getDefiAppStakerStorage() internal pure returns (DefiAppStakerStorage storage $) {
        assembly {
            $.slot := DefiAppStakerStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    /// View Functions

    function getHomeCenter() public view returns (DefiAppHomeCenter) {
        return _getDefiAppStakerStorage().homeCenter;
    }

    /// Admin Functions

    function setHomeCenter(DefiAppHomeCenter _homeCenter) external onlyOwner {
        require(address(_homeCenter) != address(0), AddressZero());
        _getDefiAppStakerStorage().homeCenter = _homeCenter;
        emit HomeCenterSet(address(_homeCenter));
    }

    /// Hooks

    function _beforeStakeHook(uint256 _amount, address _onBehalf, uint256) internal override {
        DefiAppHomeCenter center = getHomeCenter();
        require(address(center) != address(0), DefiAppStaker_HomeCenterNotSet());
        if (_amount > 0 && _onBehalf != address(0) && getUserLocks(_onBehalf).length == 0) {
            center.registerStaker(_onBehalf);
        }
    }
}
