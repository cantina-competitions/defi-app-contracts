// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MFDBase} from "./dependencies/MultiFeeDistribution/MFDBase.sol";
import {
    MFDBaseInitializerParams,
    MultiFeeDistributionStorage,
    Reward
} from "./dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {DefiAppHomeCenter} from "./DefiAppHomeCenter.sol";
import {VolatileAMMPoolHelper} from "./periphery/VolatileAMMPoolHelper.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGauge} from "./interfaces/aerodrome/IGauge.sol";

struct DefiAppStakerStorage {
    DefiAppHomeCenter homeCenter;
    IGauge gauge;
}

/// @title DefiAppStaker Contract
/// @author security@defi.app
contract DefiAppStaker is MFDBase {
    using SafeERC20 for IERC20;
    /// Events

    event SetHomeCenter(address homeCenter);
    event SetGauge(address gauge);

    /// Custom Errors
    error DefiAppStaker_homeCenterNotSet();
    error DefiAppStaker_gaugeNotSet();
    error DefiAppStaker_invalidGauge();

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

    function getGauge() public view returns (IGauge) {
        return _getDefiAppStakerStorage().gauge;
    }

    /// Admin Functions

    function setHomeCenter(DefiAppHomeCenter _homeCenter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(_homeCenter) != address(0), AddressZero());
        _getDefiAppStakerStorage().homeCenter = _homeCenter;
        emit SetHomeCenter(address(_homeCenter));
    }

    function setGauge(IGauge _gauge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(_gauge) != address(0), AddressZero());
        require(
            _gauge.isPool() && _gauge.stakingToken() == _getMFDBaseStorage().stakeToken, DefiAppStaker_invalidGauge()
        );
        DefiAppStakerStorage storage $ = _getDefiAppStakerStorage();
        IGauge lastGauge = $.gauge;
        IGauge newGauge = IGauge(_gauge);

        address prevRewardToken = address(lastGauge) != address(0) ? lastGauge.rewardToken() : address(0);
        address newRewardToken = newGauge.rewardToken();
        MultiFeeDistributionStorage storage $m = _getMFDBaseStorage();
        if (prevRewardToken == address(0)) {
            _addReward($m, newRewardToken);
        } else if (prevRewardToken != address(0) && prevRewardToken != newRewardToken) {
            Reward memory prevRewardData = $m.rewardData[prevRewardToken];
            uint256 prevRewardBal = IERC20(prevRewardToken).balanceOf(address(this));
            uint256 untracked = prevRewardBal > prevRewardData.balance ? prevRewardBal - prevRewardData.balance : 0;
            _recoverERC20(prevRewardToken, untracked);
            _removeReward($m, prevRewardToken);
            _addReward($m, newRewardToken);
        }

        $.gauge = newGauge;
        emit SetGauge(address(_gauge));
    }

    /// Hooks

    function _beforeStakeHook(uint256 _amount, address _onBehalf, uint256) internal override {
        DefiAppStakerStorage storage $ = _getDefiAppStakerStorage();
        require(address($.homeCenter) != address(0), DefiAppStaker_homeCenterNotSet());
        require(address($.gauge) != address(0), DefiAppStaker_gaugeNotSet());
        if (_amount > 0 && _onBehalf != address(0) && getUserLocks(_onBehalf).length == 0) {
            $.homeCenter.callHookRegisterStaker(_onBehalf);
        }
    }

    function _afterStakeHook(uint256 _amount, address, uint256) internal override {
        IGauge gauge = getGauge();
        // Pull any rewards from the gauge
        if (gauge.earned(address(this)) > 0) {
            gauge.getReward(address(this));
        }

        // Stake in gauge
        IERC20(_getMFDBaseStorage().stakeToken).forceApprove(address(gauge), _amount);
        gauge.deposit(_amount, address(this));
    }

    function _beforeWithdrawExpiredLocks(uint256 _amount, address) internal override {
        IGauge gauge = getGauge();
        // Pull any rewards from the gauge
        if (gauge.earned(address(this)) > 0) {
            gauge.getReward(address(this));
        }

        // Unstake from Gauge
        gauge.withdraw(_amount);
    }
}
