// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBountyManager} from "../../interfaces/radiant/IBountyManager.sol";
import {IPriceProvider} from "../../interfaces/radiant/IPriceProvider.sol";
import {MultiFeeDistribution} from "./MultiFeeDistribution.sol";
import {StakedLock, Balances, MultiFeeDistributionStorage, Reward} from "./MFDDataTypes.sol";

library MFDLogic {
    using SafeERC20 for IERC20;

    uint256 public constant AGGREGATION_EPOCH = 6 days;
    uint256 public constant RPS_PRECISION = 1e18;
    uint256 public constant PERCENT_DIVISOR = 10000;

    // Custom Errors
    error MFDLogic_addressZero();
    error MGDLogic_insufficientPermission();
    error MFDLogic_invalidAmount();
    error MFDLogic_invalidPeriod();
    error MFDLogic_invalidType();

    /**
     * @dev Library logic to stake `stakeTokens` and receive rewards. Locked tokens cannot
     * be withdrawn for defaultLockDuration and are eligible to receive rewards.
     * @param $ MultiFeeDistributionStorage storage struct.
     * @param _amount to stake.
     * @param _onBehalf address for staking.
     * @param _typeIndex lock type index.
     * @param _isRelock true if this is with relock enabled.
     */
    function stakeLogic(
        MultiFeeDistributionStorage storage $,
        uint256 _amount,
        address _onBehalf,
        uint256 _typeIndex,
        bool _isRelock
    ) external {
        if (_amount == 0) return;
        if ($.bountyManager != address(0)) {
            if (_amount < IBountyManager($.bountyManager).minDLPBalance()) revert MFDLogic_invalidAmount();
        }
        if (_typeIndex >= $.lockTypes.length) revert MFDLogic_invalidType();

        updateReward($, _onBehalf);

        StakedLock[] memory userLocks = $.userLocks[_onBehalf];
        uint256 userLocksLength = userLocks.length;

        Balances storage bal = $.userBalances[_onBehalf];
        bal.total += _amount;
        bal.locked += _amount;
        $.lockedSupply += _amount;

        {
            uint256 rewardMultiplier = $.lockTypes[_typeIndex].multiplier;
            bal.lockedWithMultiplier += (_amount * rewardMultiplier);
            $.lockedSupplyWithMultiplier += (_amount * rewardMultiplier);
        }

        uint256 lockIndex;
        StakedLock memory newLock;
        {
            uint256 lockDurationWeeks = $.lockTypes[_typeIndex].duration / AGGREGATION_EPOCH;
            uint256 unlockTime = block.timestamp + (lockDurationWeeks * AGGREGATION_EPOCH);
            lockIndex = _binarySearch(userLocks, userLocksLength, unlockTime);
            newLock = StakedLock({
                amount: _amount,
                unlockTime: unlockTime,
                multiplier: $.lockTypes[_typeIndex].multiplier,
                duration: $.lockTypes[_typeIndex].duration
            });
        }

        if (userLocksLength > 0) {
            uint256 indexToAggregate = lockIndex == 0 ? 0 : lockIndex - 1;
            if (
                (indexToAggregate < userLocksLength)
                    && (
                        userLocks[indexToAggregate].unlockTime / AGGREGATION_EPOCH == newLock.unlockTime / AGGREGATION_EPOCH
                    ) && (userLocks[indexToAggregate].multiplier == $.lockTypes[_typeIndex].multiplier)
            ) {
                $.userLocks[_onBehalf][indexToAggregate].amount = userLocks[indexToAggregate].amount + _amount;
            } else {
                _insertLock($, _onBehalf, newLock, lockIndex, userLocksLength);
                emit MultiFeeDistribution.LockerAdded(_onBehalf);
            }
        } else {
            _insertLock($, _onBehalf, newLock, lockIndex, userLocksLength);
            emit MultiFeeDistribution.LockerAdded(_onBehalf);
        }

        if (!_isRelock) {
            IERC20($.stakeToken).safeTransferFrom(msg.sender, address(this), _amount);
        }

        emit MultiFeeDistribution.Locked(
            _onBehalf, _amount, $.userBalances[_onBehalf].locked, $.lockTypes[_typeIndex].duration
        );
    }

    /**
     * @notice Claim `_user`s staking rewards
     * @param $ MultiFeeDistributionStorage storage struct.
     * @param _user address
     * @param _rewardTokens array of reward tokens
     */
    function claimRewards(MultiFeeDistributionStorage storage $, address _user, address[] memory _rewardTokens)
        external
    {
        uint256 len = _rewardTokens.length;
        for (uint256 i; i < len;) {
            address token = _rewardTokens[i];
            trackUnseenReward($, token);
            uint256 reward = $.rewards[_user][token] / RPS_PRECISION;
            if (reward > 0) {
                $.rewards[_user][token] = 0;
                $.rewardData[token].balance = $.rewardData[token].balance - reward;

                IERC20(token).safeTransfer(_user, reward);
                emit MultiFeeDistribution.RewardPaid(_user, token, reward);
            }
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Update user reward info.
     * @param _account address
     */
    function updateReward(MultiFeeDistributionStorage storage $, address _account) public {
        uint256 balance = $.userBalances[_account].lockedWithMultiplier;
        uint256 len = $.rewardTokens.length;
        for (uint256 i = 0; i < len;) {
            address token = $.rewardTokens[i];
            uint256 rpt = rewardPerToken($, token);

            Reward storage r = $.rewardData[token];
            r.rewardPerTokenStored = rpt;
            r.lastUpdateTime = lastTimeRewardApplicable($, token);

            if (_account != address(this)) {
                $.rewards[_account][token] = calculateRewardEarned($, _account, token, balance, rpt);
                $.userRewardPerTokenPaid[_account][token] = rpt;
            }
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Reward amount per token
     * @dev Reward is distributed only for locks.
     * @param _rewardToken for reward
     * @return rptStored current RPT with accumulated rewards
     */
    function rewardPerToken(MultiFeeDistributionStorage storage $, address _rewardToken)
        public
        view
        returns (uint256 rptStored)
    {
        rptStored = $.rewardData[_rewardToken].rewardPerTokenStored;
        if ($.lockedSupplyWithMultiplier > 0) {
            uint256 newReward = (lastTimeRewardApplicable($, _rewardToken) - $.rewardData[_rewardToken].lastUpdateTime)
                * $.rewardData[_rewardToken].rewardPerSecond;
            rptStored = rptStored + ((newReward * 1e18) / $.lockedSupplyWithMultiplier);
        }
    }

    /**
     * @notice Calculate earnings.
     * @param _user address of earning owner
     * @param _rewardToken address
     * @param _balance of the user
     * @param _currentRewardPerToken current RPT
     * @return earnings amount
     */
    function calculateRewardEarned(
        MultiFeeDistributionStorage storage $,
        address _user,
        address _rewardToken,
        uint256 _balance,
        uint256 _currentRewardPerToken
    ) public view returns (uint256 earnings) {
        earnings = $.rewards[_user][_rewardToken];
        uint256 realRPT = _currentRewardPerToken - $.userRewardPerTokenPaid[_user][_rewardToken];
        earnings = earnings + ((_balance * realRPT) / 1e18);
    }

    /**
     * @notice Returns reward applicable timestamp.
     * @param _rewardToken for the reward
     * @return end time of reward period
     */
    function lastTimeRewardApplicable(MultiFeeDistributionStorage storage $, address _rewardToken)
        public
        view
        returns (uint256)
    {
        uint256 periodFinish = $.rewardData[_rewardToken].periodFinish;
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Track unseen rewards sent to the contract.
     * @dev for rewards other than RDNT token, every 24 hours we check if new
     *  rewards were sent to the contract or accrued.
     * @param _token address
     */
    function trackUnseenReward(MultiFeeDistributionStorage storage $, address _token) public {
        if (_token == address(0)) revert MFDLogic_addressZero();
        // if (_token == $.emissionToken) {
        //     return;
        // }
        Reward storage r = $.rewardData[_token];
        uint256 periodFinish = r.periodFinish;
        if (periodFinish == 0) revert MFDLogic_invalidPeriod();
        if (periodFinish < block.timestamp + $.rewardDuration - $.rewardsLookback) {
            uint256 unseen = IERC20(_token).balanceOf(address(this)) - r.balance;
            if (unseen > 0) {
                _handleUnseenReward($, _token, unseen);
            }
        }
    }

    /// Private functions

    /**
     * @notice Add new lockings
     * @dev We keep the array to be sorted by unlock time.
     * @param user address to insert lock for.
     * @param newLock new lock info.
     * @param index of where to store the new lock.
     * @param lockLength length of the lock array.
     */
    function _insertLock(
        MultiFeeDistributionStorage storage $,
        address user,
        StakedLock memory newLock,
        uint256 index,
        uint256 lockLength
    ) private {
        StakedLock[] storage locks = $.userLocks[user];
        locks.push();
        for (uint256 j = lockLength; j > index;) {
            locks[j] = locks[j - 1];
            unchecked {
                j--;
            }
        }
        locks[index] = newLock;
    }

    /**
     * @notice Adds new rewards to state, distributes to ops treasury and resets reward period.
     * @dev If prev reward period is not done, then it resets `rewardPerSecond` and restarts period
     * @param _rewardToken address
     * @param _rewardAmt amount
     */
    function _handleUnseenReward(MultiFeeDistributionStorage storage $, address _rewardToken, uint256 _rewardAmt)
        private
    {
        address _opsTreasury = $.opsTreasury;
        uint256 _operationExpenseRatio = $.operationExpenseRatio;
        if (_opsTreasury != address(0) && _operationExpenseRatio != 0) {
            uint256 opExAmount = (_rewardAmt * _operationExpenseRatio) / PERCENT_DIVISOR;
            if (opExAmount != 0) {
                IERC20(_rewardToken).safeTransfer(_opsTreasury, opExAmount);
                _rewardAmt -= opExAmount;
            }
        }

        Reward storage r = $.rewardData[_rewardToken];
        if (block.timestamp >= r.periodFinish) {
            r.rewardPerSecond = (_rewardAmt * RPS_PRECISION) / $.rewardDuration;
        } else {
            uint256 remaining = r.periodFinish - block.timestamp;
            uint256 leftover = (remaining * r.rewardPerSecond) / RPS_PRECISION;
            r.rewardPerSecond = ((_rewardAmt + leftover) * RPS_PRECISION) / $.rewardDuration;
        }

        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + $.rewardDuration;
        r.balance = r.balance + _rewardAmt;

        uint256 rewardUsdValue = 1; // TODO: Implement method to get USD value of the `_rewardAmt`
        emit MultiFeeDistribution.RevenueEarned(_rewardToken, _rewardAmt, rewardUsdValue);
    }

    function _binarySearch(StakedLock[] memory _locks, uint256 _length, uint256 _unlockTime)
        private
        pure
        returns (uint256)
    {
        uint256 low = 0;
        uint256 high = _length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_locks[mid].unlockTime < _unlockTime) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }
}
