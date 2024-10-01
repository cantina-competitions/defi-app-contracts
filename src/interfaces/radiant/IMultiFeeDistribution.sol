// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LockedBalance, Balances} from "./LockedBalance.sol";
import {IFeeDistribution} from "./IFeeDistribution.sol";
import {IMintableToken} from "../IMintableToken.sol";

interface IMultiFeeDistribution is IFeeDistribution {
    function exit(bool _claimRewards) external;

    function stake(uint256 _amount, address _onBehalfOf, uint256 _typeIndex) external;

    function emissionToken() external view returns (IMintableToken);

    function getPriceProvider() external view returns (address);

    function lockInfo(address _user) external view returns (LockedBalance[] memory);

    function autocompoundDisabled(address _user) external view returns (bool);

    function defaultLockIndex(address _user) external view returns (uint256);

    function autoRelockDisabled(address _user) external view returns (bool);

    function totalBalance(address _user) external view returns (uint256);

    function lockedBalance(address _user) external view returns (uint256);

    function lockedBalances(address _user)
        external
        view
        returns (uint256, uint256, uint256, uint256, LockedBalance[] memory);

    function getBalances(address _user) external view returns (Balances memory);

    function zapVestingToLp(address _address) external returns (uint256);

    function claimableRewards(address _account) external view returns (IFeeDistribution.RewardData[] memory rewards);

    function setDefaultRelockTypeIndex(uint256 _index) external;

    function daoTreasury() external view returns (address);

    function stakingToken() external view returns (address);

    function userSlippage(address) external view returns (uint256);

    function claimFromConverter(address) external;

    function vestTokens(address _user, uint256 _amount, bool _withPenalty) external;
}

interface IMFDPlus is IMultiFeeDistribution {
    function getLastClaimTime(address _user) external returns (uint256);

    function claimBounty(address _user, bool _execute) external returns (bool issueBaseBounty);

    function claimCompound(address _user, bool _execute, uint256 _slippage) external returns (uint256 bountyAmt);

    function setAutocompound(bool _state, uint256 _slippage) external;

    function setUserSlippage(uint256 _slippage) external;

    function toggleAutocompound() external;
}
