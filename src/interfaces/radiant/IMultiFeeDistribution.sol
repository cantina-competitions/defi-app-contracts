// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {StakedLock, Balances, ClaimableReward} from "../../dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {IMintableToken} from "../IMintableToken.sol";

interface IMultiFeeDistribution {
    function emissionToken() external view returns (address);

    function stakeToken() external view returns (address);

    function stake(uint256 _amount, address _onBehalfOf, uint256 _typeIndex) external;

    function getUserLocks(address _user) external view returns (StakedLock[] memory);

    function getUserBalances(address _user) external view returns (Balances memory);

    function autocompoundDisabled(address _user) external view returns (bool);

    function getDefaultLockIndex(address _user) external view returns (uint256);

    function autoRelockDisabled(address _user) external view returns (bool);

    function getUserClaimableRewards(address _account) external view returns (ClaimableReward[] memory rewards);

    function setDefaultLockIndex(uint256 _index) external;

    function userSlippage(address) external view returns (uint256);

    function addReward(address rewardsToken) external;

    function removeReward(address _rewardToken) external;

    function claimAndCompound(address) external;
}

interface IMFDPlus is IMultiFeeDistribution {
    function getLastClaimTime(address _user) external returns (uint256);

    function claimBounty(address _user, bool _execute) external returns (bool issueBaseBounty);

    function claimCompound(address _user, bool _execute, uint256 _slippage) external returns (uint256 bountyAmt);

    function setAutocompound(bool _state, uint256 _slippage) external;

    function setUserSlippage(uint256 _slippage) external;

    function toggleAutocompound() external;
}
