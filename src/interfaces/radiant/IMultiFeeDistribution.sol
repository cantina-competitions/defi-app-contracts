// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {StakedLock, Balances} from "../../reference/MultiFeeDistribution/MFDDataTypes.sol";
import {IFeeDistribution} from "./IFeeDistribution.sol";
import {IMintableToken} from "../IMintableToken.sol";

interface IMultiFeeDistribution is IFeeDistribution {
    function emissionToken() external view returns (address);

    function stakeToken() external view returns (address);

    function stake(uint256 _amount, address _onBehalfOf, uint256 _typeIndex) external;

    function getStakedLocks(address _user) external view returns (StakedLock[] memory);

    function autocompoundDisabled(address _user) external view returns (bool);

    function defaultLockIndex(address _user) external view returns (uint256);

    function autoRelockDisabled(address _user) external view returns (bool);

    function stakedBalance(address _user) external view returns (uint256);

    function getBalances(address _user) external view returns (Balances memory);

    function zapEmissionsToStake(address _address) external returns (uint256);

    function claimableRewards(address _account) external view returns (IFeeDistribution.RewardData[] memory rewards);

    function setDefaultRelockTypeIndex(uint256 _index) external;

    function userSlippage(address) external view returns (uint256);

    function claimFromConverter(address) external;
}

interface IMFDPlus is IMultiFeeDistribution {
    function getLastClaimTime(address _user) external returns (uint256);

    function claimBounty(address _user, bool _execute) external returns (bool issueBaseBounty);

    function claimCompound(address _user, bool _execute, uint256 _slippage) external returns (uint256 bountyAmt);

    function setAutocompound(bool _state, uint256 _slippage) external;

    function setUserSlippage(uint256 _slippage) external;

    function toggleAutocompound() external;
}
