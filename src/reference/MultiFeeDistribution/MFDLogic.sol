// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBountyManager} from "../../interfaces/radiant/IBountyManager.sol";
import {IChefIncentivesController} from "../../interfaces/radiant/IChefIncentivesController.sol";
import {IPriceProvider} from "../../interfaces/radiant/IPriceProvider.sol";
import {MultiFeeDistribution} from "./MultiFeeDistribution.sol";
import {LockedBalance, Balances, MultiFeeDistributionStorage, Reward} from "./MFDDataTypes.sol";

library MFDLogic {
    using SafeERC20 for IERC20;

    uint256 public constant AGGREGATION_EPOCH = 6 days;
    uint256 public constant RPS_PRECISION = 1e18;
    uint256 public constant RATIO_DIVISOR = 10000;

    // Custom Errors
    error MFDLogic_addressZero();
    error MGDLogic_insufficientPermission();
    error MFDLogic_invalidAmount();
    error MFDLogic_invalidPeriod();
    error MFDLogic_invalidType();

    /**
     * @notice Stake tokens to receive rewards.
     * @dev Locked tokens cannot be withdrawn for defaultLockDuration and are eligible to receive rewards.
     * @param $ MultiFeeDistributionStorage struct.
     * @param _amount to stake.
     * @param _onBehalf address for staking.
     * @param _typeIndex lock type index.
     * @param _isRelock true if this is with relock enabled.
     */
    function stake(
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
        if (_typeIndex >= $.lockPeriods.length) revert MFDLogic_invalidType();

        updateReward($, _onBehalf);

        LockedBalance[] memory userLocks = $.userLocks[_onBehalf];
        uint256 userLocksLength = userLocks.length;

        Balances storage bal = $.userBalances[_onBehalf];
        bal.total = bal.total + _amount;

        bal.locked = bal.locked + _amount;
        $.lockedSupply += _amount;

        {
            uint256 rewardMultiplier = $.lockMultipliers[_typeIndex];
            bal.lockedWithMultiplier += (_amount * rewardMultiplier);
            $.lockedSupplyWithMultiplier += (_amount * rewardMultiplier);
        }

        uint256 lockIndex;
        LockedBalance memory newLock;
        {
            uint256 lockDurationWeeks = $.lockPeriods[_typeIndex] / AGGREGATION_EPOCH;
            uint256 unlockTime = block.timestamp + (lockDurationWeeks * AGGREGATION_EPOCH);
            lockIndex = _binarySearch(userLocks, userLocksLength, unlockTime);
            newLock = LockedBalance({
                amount: _amount,
                unlockTime: unlockTime,
                multiplier: $.lockMultipliers[_typeIndex],
                duration: $.lockPeriods[_typeIndex]
            });
        }

        if (userLocksLength > 0) {
            uint256 indexToAggregate = lockIndex == 0 ? 0 : lockIndex - 1;
            if (
                (indexToAggregate < userLocksLength)
                    && (
                        userLocks[indexToAggregate].unlockTime / AGGREGATION_EPOCH == newLock.unlockTime / AGGREGATION_EPOCH
                    ) && (userLocks[indexToAggregate].multiplier == $.lockMultipliers[_typeIndex])
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
            IERC20($.stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
        }

        IChefIncentivesController($.incentivesController).afterLockUpdate(_onBehalf);
        emit MultiFeeDistribution.Locked(
            _onBehalf,
            _amount,
            $.userBalances[_onBehalf].locked,
            $.lockPeriods[_typeIndex],
            $.stakingToken != $.emissionToken
        );
    }

    /**
     * @notice User gets reward
     * @param _user address
     * @param _rewardTokens array of reward tokens
     */
    function getReward(MultiFeeDistributionStorage storage $, address _user, address[] memory _rewardTokens) external {
        uint256 len = _rewardTokens.length;
        IChefIncentivesController cic = IChefIncentivesController($.incentivesController);
        cic.setEligibilityExempt(_user, true);
        for (uint256 i; i < len;) {
            address token = _rewardTokens[i];
            notifyUnseenReward($, token);
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
        cic.setEligibilityExempt(_user, false);
        cic.afterLockUpdate(_user);
    }

    function vestTokens(MultiFeeDistributionStorage storage $, address _user, uint256 _amount, bool _withPenalty)
        external
    {
        if (!$.emissionDistributors[msg.sender]) revert MGDLogic_insufficientPermission();
        if (_amount == 0) return;

        if (_user == address(this)) {
            // minting to this contract adds the new tokens as incentives for lockers
            _notifyReward($, address($.emissionToken), _amount);
            return;
        }

        Balances storage bal = $.userBalances[_user];
        bal.total = bal.total + _amount;
        if (_withPenalty) {
            bal.earned = bal.earned + _amount;
            LockedBalance[] storage earnings = $.userEarnings[_user];

            uint256 currentDay = block.timestamp / 1 days;
            uint256 lastIndex = earnings.length > 0 ? earnings.length - 1 : 0;
            uint256 vestingDurationDays = $.vestDuration / 1 days;

            // We check if an entry for the current day already exists. If yes, add new amount to that entry
            if (earnings.length > 0 && (earnings[lastIndex].unlockTime / 1 days) == currentDay + vestingDurationDays) {
                earnings[lastIndex].amount = earnings[lastIndex].amount + _amount;
            } else {
                // If there is no entry for the current day, create a new one
                uint256 unlockTime = block.timestamp + $.vestDuration;
                earnings.push(
                    LockedBalance({amount: _amount, unlockTime: unlockTime, multiplier: 1, duration: $.vestDuration})
                );
            }
        } else {
            bal.unlocked = bal.unlocked + _amount;
        }
    }

    /**
     * @notice Update user reward info.
     * @param _account address
     */
    function updateReward(MultiFeeDistributionStorage storage $, address _account) public {
        uint256 balance = $.userBalances[_account].lockedWithMultiplier;
        uint256 length = $.rewardTokens.length;
        for (uint256 i = 0; i < length;) {
            address token = $.rewardTokens[i];
            uint256 rpt = rewardPerToken($, token);

            Reward storage r = $.rewardData[token];
            r.rewardPerTokenStored = rpt;
            r.lastUpdateTime = lastTimeRewardApplicable($, token);

            if (_account != address(this)) {
                $.rewards[_account][token] = earned($, _account, token, balance, rpt);
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
    function earned(
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
     * @notice Notify unseen rewards.
     * @dev for rewards other than RDNT token, every 24 hours we check if new
     *  rewards were sent to the contract or accrued via aToken interest.
     * @param token address
     */
    function notifyUnseenReward(MultiFeeDistributionStorage storage $, address token) public {
        if (token == address(0)) revert MFDLogic_addressZero();
        if (token == $.emissionToken) {
            return;
        }
        Reward storage r = $.rewardData[token];
        uint256 periodFinish = r.periodFinish;
        if (periodFinish == 0) revert MFDLogic_invalidPeriod();
        if (periodFinish < block.timestamp + $.rewardDuration - $.rewardsLookback) {
            uint256 unseen = IERC20(token).balanceOf(address(this)) - r.balance;
            if (unseen > 0) {
                _notifyReward($, token, unseen);
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
        LockedBalance memory newLock,
        uint256 index,
        uint256 lockLength
    ) internal {
        LockedBalance[] storage locks = $.userLocks[user];
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
     * @notice Add new reward.
     * @dev If prev reward period is not done, then it resets `rewardPerSecond` and restarts period
     * @param _rewardToken address
     * @param _reward amount
     */
    function _notifyReward(MultiFeeDistributionStorage storage $, address _rewardToken, uint256 _reward) internal {
        address _operationExpenseReceiver = $.operationExpenseReceiver;
        uint256 _operationExpenseRatio = $.operationExpenseRatio;
        if (_operationExpenseReceiver != address(0) && _operationExpenseRatio != 0) {
            uint256 opExAmount = (_reward * _operationExpenseRatio) / RATIO_DIVISOR;
            if (opExAmount != 0) {
                IERC20(_rewardToken).safeTransfer(_operationExpenseReceiver, opExAmount);
                _reward -= opExAmount;
            }
        }

        Reward storage r = $.rewardData[_rewardToken];
        if (block.timestamp >= r.periodFinish) {
            r.rewardPerSecond = (_reward * RPS_PRECISION) / $.rewardDuration;
        } else {
            uint256 remaining = r.periodFinish - block.timestamp;
            uint256 leftover = (remaining * r.rewardPerSecond) / RPS_PRECISION;
            r.rewardPerSecond = ((_reward + leftover) * RPS_PRECISION) / $.rewardDuration;
        }

        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + $.rewardDuration;
        r.balance = r.balance + _reward;

        emit MultiFeeDistribution.RevenueEarned(_rewardToken, _reward);
        uint256 lpUsdValue = IPriceProvider($.priceProvider).getRewardTokenPrice(_rewardToken, _reward);
        emit MultiFeeDistribution.NewTransferAdded(_rewardToken, lpUsdValue);
    }

    function _binarySearch(LockedBalance[] memory _locks, uint256 _length, uint256 _unlockTime)
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
