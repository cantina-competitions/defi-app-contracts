// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {RecoverERC20} from "../helpers/RecoverERC20.sol";
// import {IChefIncentivesController} from "../../interfaces/radiant/IChefIncentivesController.sol"; // TODO: confirm remove
import {IBountyManager} from "../../interfaces/radiant/IBountyManager.sol";
import {IMultiFeeDistribution, IFeeDistribution} from "../../interfaces/radiant/IMultiFeeDistribution.sol";
import {
    Balances,
    LockType,
    Reward,
    StakedLock,
    MultiFeeInitializerParams,
    MultiFeeDistributionStorage
} from "./MFDDataTypes.sol";
import {MFDLogic} from "./MFDLogic.sol";

/// @title Multi Fee Distribution Contract
/// @author security@defi.app
contract MultiFeeDistribution is
    IMultiFeeDistribution,
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    RecoverERC20,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /// Constants
    uint256 public constant PERCENT_DIVISOR = 10000; // 100%
    uint256 public constant MAX_SLIPPAGE = 9000; // 10% (used for compounding)
    uint256 public constant DEFAULT_LOCK_INDEX = 1; // Default lock index
    uint256 private constant _RPS_PRECISION = 1e12; // Precision for reward per second
    uint256 private constant _QUART = 25000; //  25%
    uint256 private constant _HALF = 65000; //  65%
    uint256 private constant _WHOLE = 100000; // 100%

    /// Events
    event Locked(address indexed user, uint256 amount, uint256 stakedBalance, uint256 indexed duration);
    event Withdrawn(
        address indexed user, uint256 receivedAmount, uint256 StakedLock, uint256 penalty, uint256 burn, bool isLP
    );
    event RewardPaid(address indexed user, address indexed rewardToken, uint256 rewardAmount);
    event Relocked(address indexed user, uint256 amount, uint256 lockIndex);
    event BountyManagerUpdated(address indexed bounty);
    event RewardConverterUpdated(address indexed rewardCompounder);
    event LockTypesUpdated(LockType[] lockTypes);
    event StakeTokenUpdated(address indexed stakeToken);
    event RewardAdded(address indexed rewardToken);
    event LockerAdded(address indexed locker);
    event LockerRemoved(address indexed locker);
    event RevenueEarned(address indexed asset, uint256 assetAmount, uint256 usdValue);
    event OperationExpensesUpdated(address indexed opsTreasury, uint256 operationExpenseRatio);
    event UserAutocompoundUpdated(address indexed user, bool indexed disabled);
    event UserSlippageUpdated(address indexed user, uint256 slippage);

    /// Custom Errors
    error AddressZero();
    error AmountZero();
    error InvalidRatio();
    error InvalidLookback();
    error InsufficientPermission();
    error AlreadyAdded();
    error InvalidType();
    error InvalidAmount();
    error InvalidPeriod();
    error InvalidAddress();
    error InvalidAction();

    /// State Variables
    bytes32 private constant MultiFeeDistributionStorageLocation =
    // keccak256(abi.encodePacked("MultiFeeDistribution"))
     0x3b5a7af972b52eb289523ec10a91ac1f06e8f37a3acd3ab1a1e292feea803551;

    function _getMultiFeeDistributionStorage() private pure returns (MultiFeeDistributionStorage storage $) {
        assembly {
            $.slot := MultiFeeDistributionStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializer
     *  First reward MUST be the `emissionToken`
     * @param initParams MultiFeeInitializerParams
     * - emissionToken address
     * - stakeToken address
     * - rewardStreamTime Duration that rev rewards are streamed over
     * - rewardsLookback Duration that rewards loop back
     * - initLockTypes array of LockType
     * - defaultLockTypeIndex index in `initLockTypes` to be used as default
     * - lockZap contract address
     */
    function initialize(MultiFeeInitializerParams calldata initParams) public initializer {
        _checkNoZeroAddress(initParams.emissionToken);
        _checkNoZeroAddress(initParams.stakeToken);
        _checkNoZeroAddress(initParams.lockZap);
        _checkZeroAmount(initParams.rewardStreamTime);
        _checkZeroAmount(initParams.rewardsLookback);
        _checkZeroAmount(initParams.initLockTypes.length);

        __Ownable_init(_msgSender());
        __Pausable_init();

        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.emissionToken = initParams.emissionToken;
        $.stakeToken = initParams.stakeToken;
        $.lockZap = initParams.lockZap;

        _setLockTypes(initParams.initLockTypes);

        if (initParams.rewardsLookback > initParams.rewardStreamTime) revert InvalidLookback();
        $.rewardStreamTime = initParams.rewardStreamTime;
        $.rewardsLookback = initParams.rewardsLookback;

        $.rewardTokens.push(initParams.emissionToken);
        $.rewardData[initParams.emissionToken].lastUpdateTime = block.timestamp;
    }

    /// View functions

    /**
     * @notice Return emission token.
     */
    function emissionToken() external view returns (address) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.emissionToken;
    }

    /**
     * @notice Return stake token.
     */
    function stakeToken() external view returns (address) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.stakeToken;
    }

    /**
     * @notice Return eligible lock types.
     */
    function getLockTypes() external view returns (LockType[] memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.lockTypes;
    }

    /**
     * @notice Returns total locked staked token.
     */
    function getLockedSupply() external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.lockedSupply;
    }

    /**
     * @notice Returns total locked staked token with multiplier.
     */
    function getLockedSupplyWithMultiplier() external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.lockedSupplyWithMultiplier;
    }

    /**
     * @notice Get all user's locks
     */
    function getUserLocks(address _user) public view returns (StakedLock[] memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.userLocks[_user];
    }

    /**
     * @notice Returns sum of user's expired locked balances
     */
    function getExpiredStakeBalance(address _user) public view returns (uint256 unlockable) {
        StakedLock[] memory locks = getUserLocks(_user);
        uint256 len = locks.length;
        uint256 currentTimestamp = block.timestamp;
        for (uint256 i; i < len;) {
            if (locks[i].unlockTime <= currentTimestamp) {
                unlockable = unlockable + locks[i].amount;
            }
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Returns the recorded `Balance` struct of  `_user`.
     *  - total // total amount of staked tokens (both locked and unlocked)
     *  - locked // total locked staked tokens
     *  - unlocked // total unlocked stake tokens (can be withdrawn)
     * - lockedWithMultiplier // Multiplied locked amount
     */
    function getUserBalances(address _user) external view returns (Balances memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.userBalances[_user];
    }

    /**
     * @notice Returns the default lock index for `_user`.
     */
    function defaultLockIndex(address _user) external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.defaultLockIndex[_user];
    }

    /**
     * @notice Returns the `_rewardToken` amount estimated for the `rewardStreamTime` period.
     */
    function getRewardForDuration(address _rewardToken) external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return ($.rewardData[_rewardToken].rewardPerSecond * $.rewardStreamTime) / _RPS_PRECISION;
    }

    /**
     * @notice Returns `_user`s slippage.
     */
    function userSlippage(address _user) external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.userSlippage[_user];
    }

    /**
     * @notice Returns if `_user` is autocompound disabled.
     */
    function autocompoundDisabled(address _user) external view returns (bool) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.autocompoundDisabled[_user];
    }

    /**
     * @notice Returns if `_user` is autocompound disabled.
     */
    function autoRelockDisabled(address _user) external view returns (bool) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.autoRelockDisabled[_user];
    }

    /**
     * @notice  Total staked tokens locked of the `_user`.
     * @param _user address
     * @return locked amount
     */
    function stakedBalance(address _user) external view returns (uint256 locked) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        StakedLock[] storage locks = $.userLocks[_user];
        uint256 length = locks.length;
        uint256 currentTimestamp = block.timestamp;
        for (uint256 i; i < length;) {
            if (locks[i].unlockTime > currentTimestamp) {
                locked = locked + locks[i].amount;
            }
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Address and claimable amount of all reward tokens for the given account.
     * @param _account for rewards
     * @return rewardsData array of rewards
     */
    function claimableRewards(address _account)
        public
        view
        returns (IFeeDistribution.RewardData[] memory rewardsData)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        rewardsData = new IFeeDistribution.RewardData[]($.rewardTokens.length);

        uint256 length = $.rewardTokens.length;
        for (uint256 i; i < length;) {
            rewardsData[i].token = $.rewardTokens[i];
            rewardsData[i].amount = MFDLogic.calculateRewardEarned(
                $,
                _account,
                rewardsData[i].token,
                $.userBalances[_account].lockedWithMultiplier,
                MFDLogic.rewardPerToken($, rewardsData[i].token)
            ) / _RPS_PRECISION;
            unchecked {
                i++;
            }
        }
        return rewardsData;
    }

    /// Public functions

    /**
     * @notice Claims bounty.
     * @dev Remove expired locks
     * @param _user address
     * @param _execute true if this is actual execution
     * @return issueBaseBounty true if needs to issue base bounty
     */
    function claimBounty(address _user, bool _execute) public whenNotPaused returns (bool issueBaseBounty) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();

        if (msg.sender != $.bountyManager) revert InsufficientPermission();

        uint256 unlockable = getExpiredStakeBalance(_user);
        if (unlockable == 0) {
            return (false);
        } else {
            issueBaseBounty = true;
        }

        if (!_execute) {
            return (issueBaseBounty);
        }
        // Withdraw the user's expried locks
        _withdrawExpiredLocks(_user, false, true, $.userLocks[_user].length);
    }

    /**
     * @notice Claim all staking `_rewards` received for staking by `msg.sender`.
     * @param _rewardTokens array of reward tokens
     */
    function claimRewards(address[] memory _rewardTokens) public whenNotPaused {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        MFDLogic.updateReward($, msg.sender);
        MFDLogic.claimRewards($, msg.sender, _rewardTokens);
    }

    /**
     * @notice Claim all pending staking rewards.
     */
    function claimAllRewards() external {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return claimRewards($.rewardTokens);
    }

    /**
     * @notice Pause MFD functionalities
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @notice Resume MFD functionalities
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /// Setters

    /**
     * @notice Set allowed for `emissionDistributors`
     * @param _distributors array of address
     * @param _allowed array of bool
     */
    function setEmissionDistributors(address[] calldata _distributors, bool[] calldata _allowed) external onlyOwner {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 len = _distributors.length;
        if (len != _allowed.length) revert InvalidAmount();
        for (uint256 i; i < len;) {
            _checkNoZeroAddress(_distributors[i]);
            $.emissionDistributors[_distributors[i]] = _allowed[i];
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Sets bounty manager contract.
     * @param _bountyManager contract address
     */
    function setBountyManager(address _bountyManager) external onlyOwner {
        _checkNoZeroAddress(_bountyManager);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.bountyManager = _bountyManager;
        $.emissionDistributors[_bountyManager] = true;
        emit BountyManagerUpdated(_bountyManager);
    }

    /**
     * @notice Sets reward converter contract.
     * @param _rewardCompounder contract address
     */
    function addRewardConverter(address _rewardCompounder) external onlyOwner {
        _checkNoZeroAddress(_rewardCompounder);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.rewardCompounder = _rewardCompounder;
        emit RewardConverterUpdated(_rewardCompounder);
    }

    /**
     * @notice Sets the lock types: period and reward multipliers.
     * @param _lockTypes array of LockType
     */
    function setLockTypes(LockType[] memory _lockTypes) external onlyOwner {
        _setLockTypes(_lockTypes);
    }

    /**
     * @notice Add a new reward token to be distributed to stakers.
     * @param _rewardToken address
     */
    function addReward(address _rewardToken) external {
        _checkNoZeroAddress(_rewardToken);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (!$.emissionDistributors[msg.sender]) revert InsufficientPermission();
        if ($.rewardData[_rewardToken].lastUpdateTime != 0) revert AlreadyAdded();
        $.rewardTokens.push(_rewardToken);

        Reward storage rd = $.rewardData[_rewardToken];
        rd.lastUpdateTime = block.timestamp;
        rd.periodFinish = block.timestamp;

        $.isRewardToken[_rewardToken] = true;
        emit RewardAdded(_rewardToken);
    }

    /**
     * @notice Remove an existing reward token.
     * @param _rewardToken address to be removed
     */
    function removeReward(address _rewardToken) external {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (!$.emissionDistributors[msg.sender]) revert InsufficientPermission();

        bool isTokenFound;
        uint256 indexToRemove;

        uint256 length = $.rewardTokens.length;
        for (uint256 i; i < length; i++) {
            if ($.rewardTokens[i] == _rewardToken) {
                isTokenFound = true;
                indexToRemove = i;
                break;
            }
        }

        if (!isTokenFound) revert InvalidAddress();

        // Reward token order is changed, but that doesn't have an impact
        if (indexToRemove < length - 1) {
            $.rewardTokens[indexToRemove] = $.rewardTokens[length - 1];
        }

        $.rewardTokens.pop();

        // Scrub historical reward token data
        Reward storage rd = $.rewardData[_rewardToken];
        rd.lastUpdateTime = 0;
        rd.periodFinish = 0;
        rd.balance = 0;
        rd.rewardPerSecond = 0;
        rd.rewardPerTokenStored = 0;

        $.isRewardToken[_rewardToken] = false;
    }

    /**
     * @notice Set default lock type index for user relock.
     * @param _index of default lock length
     */
    function setDefaultRelockTypeIndex(uint256 _index) external {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_index >= $.lockTypes.length) revert InvalidType();
        $.defaultLockIndex[msg.sender] = _index;
    }

    /**
     * @notice Sets the autocompound status and the desired max slippage.
     * @param _enable true if autocompound is to be enabled
     * @param _slippage the maximum amount of slippage that the user will incur for each compounding trade
     */
    function setAutocompound(bool _enable, uint256 _slippage) external {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_enable == $.autocompoundDisabled[msg.sender]) {
            toggleAutocompound();
        }
        setUserSlippage(_slippage);
    }

    /**
     * @notice Set what slippage to use for tokens traded during the auto compound process on be_HALF of the user
     * @param _slippage the maximum amount of slippage that the user will incur for each compounding trade
     */
    function setUserSlippage(uint256 _slippage) public {
        if (_slippage < MAX_SLIPPAGE || _slippage >= PERCENT_DIVISOR) {
            revert InvalidAmount();
        }
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.userSlippage[msg.sender] = _slippage;
        emit UserSlippageUpdated(msg.sender, _slippage);
    }

    /**
     * @notice Toggle a users autocompound status.
     */
    function toggleAutocompound() public {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        bool newStatus = !$.autocompoundDisabled[msg.sender];
        $.autocompoundDisabled[msg.sender] = newStatus;
        emit UserAutocompoundUpdated(msg.sender, newStatus);
    }

    /**
     * @notice Set relock status
     * @param status true if auto relock is enabled.
     */
    function setRelock(bool status) external virtual {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.autoRelockDisabled[msg.sender] = !status;
    }

    /**
     * @notice Sets the lookback period
     * @param _lookback in seconds
     */
    function setLookback(uint256 _lookback) external onlyOwner {
        _checkZeroAmount(_lookback);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_lookback > $.rewardStreamTime) revert InvalidLookback();
        $.rewardsLookback = _lookback;
        // TODO add event here
    }

    /**
     * @notice Set operation expenses account
     * @param _opsTreasury Address to receive operation expenses
     * @param _operationExpenseRatio Proportion of operation expense
     */
    function setOperationExpenses(address _opsTreasury, uint256 _operationExpenseRatio) external onlyOwner {
        _checkNoZeroAddress(_opsTreasury);
        if (_operationExpenseRatio > PERCENT_DIVISOR) revert InvalidRatio();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.opsTreasury = _opsTreasury;
        $.operationExpenseRatio = _operationExpenseRatio;
        emit OperationExpensesUpdated(_opsTreasury, _operationExpenseRatio);
    }

    /// External functions

    /**
     * @notice Stake tokens to receive rewards.
     * @dev Locked tokens cannot be withdrawn for lock duration and are eligible to receive rewards.
     * @param _amount to stake.
     * @param _onBehalf address for staking.
     * @param _typeIndex lock type index.
     */
    function stake(uint256 _amount, address _onBehalf, uint256 _typeIndex) external whenNotPaused {
        MFDLogic.stakeLogic(_getMultiFeeDistributionStorage(), _amount, _onBehalf, _typeIndex, false);
    }

    /**
     * @notice Withdraw expired locks with options
     * @param _address for withdraw
     * @param _limit of lock length for withdraw
     * @param _isRelock option to relock
     * @return withdraw amount
     */
    function withdrawExpiredLocksForWithOptions(address _address, uint256 _limit, bool _isRelock)
        external
        returns (uint256)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_limit == 0) _limit = $.userLocks[_address].length;

        return _withdrawExpiredLocks(_address, _isRelock, true, _limit);
    }

    function zapEmissionsToStake(address _address) external returns (uint256 zapped) {}

    /**
     * @notice Claim rewards by converter.
     * @dev Rewards are transfered to converter. In the Radiant Capital protocol
     * 		the role of the Converter is taken over by Compounder.sol.
     * @param _onBehalf address to claim.
     */
    function claimFromConverter(address _onBehalf) external whenNotPaused {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (msg.sender != $.rewardCompounder) revert InsufficientPermission();
        MFDLogic.updateReward($, _onBehalf);
        uint256 length = $.rewardTokens.length;
        for (uint256 i; i < length;) {
            address token = $.rewardTokens[i];
            if (token != $.emissionToken) {
                MFDLogic.trackUnseenReward($, token);
                uint256 reward = $.rewards[_onBehalf][token] / _RPS_PRECISION;
                if (reward > 0) {
                    $.rewards[_onBehalf][token] = 0;
                    $.rewardData[token].balance = $.rewardData[token].balance - reward;

                    IERC20(token).safeTransfer($.rewardCompounder, reward);
                    emit RewardPaid(_onBehalf, token, reward);
                }
            }
            unchecked {
                i++;
            }
        }
        $.lastClaimTime[_onBehalf] = block.timestamp;
    }

    /**
     * @notice Restake any expired locks.
     */
    function relock() external virtual {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 amount = _withdrawExpiredLocks(msg.sender, true, true, $.userLocks[msg.sender].length);
        emit Relocked(msg.sender, amount, $.defaultLockIndex[msg.sender]);
    }

    /**
     * @notice Requalify user
     */
    // function requalify() external {
    //     requalifyFor(msg.sender);
    // }

    /**
     * @notice Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders.
     * @param tokenAddress to recover.
     * @param tokenAmount to recover.
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        _recoverERC20(tokenAddress, tokenAmount);
    }

    /// Internal functions

    /**
     * @notice Withdraw all lockings tokens where the unlock time has passed
     * @param _user address
     * @param _limit limit for looping operation
     * @return lockAmount withdrawable lock amount
     * @return lockAmountWithMultiplier withdraw amount with multiplier
     */
    function _cleanWithdrawableLocks(address _user, uint256 _limit)
        internal
        returns (uint256 lockAmount, uint256 lockAmountWithMultiplier)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        StakedLock[] storage locks = $.userLocks[_user];

        if (locks.length != 0) {
            uint256 length = locks.length <= _limit ? locks.length : _limit;
            uint256 i;
            while (i < length && locks[i].unlockTime <= block.timestamp) {
                lockAmount += locks[i].amount;
                lockAmountWithMultiplier += (locks[i].amount * locks[i].multiplier);
                i = i + 1;
            }
            uint256 locksLength = locks.length;
            for (uint256 j = i; j < locksLength;) {
                locks[j - i] = locks[j];
                unchecked {
                    j++;
                }
            }
            for (uint256 j = 0; j < i;) {
                locks.pop();
                unchecked {
                    j++;
                }
            }
            if (locks.length == 0) {
                emit LockerRemoved(_user);
            }
        }
    }

    /**
     * @notice Withdraw all expired locks for `_address`.
     * @param _address of the user.
     * @param _isRelock true if withdraw with relock
     * @param _doTransfer true to transfer tokens to user
     * @param _limit limit for looping operation
     * @return amount for withdraw
     * //
     */
    function _withdrawExpiredLocks(address _address, bool _isRelock, bool _doTransfer, uint256 _limit)
        internal
        whenNotPaused
        returns (uint256 amount)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_isRelock && _address != msg.sender && $.lockZap != msg.sender) revert InsufficientPermission();
        MFDLogic.updateReward($, _address);

        uint256 amountWithMultiplier;
        Balances storage bal = $.userBalances[_address];
        (amount, amountWithMultiplier) = _cleanWithdrawableLocks(_address, _limit);
        bal.locked = bal.locked - amount;
        bal.lockedWithMultiplier = bal.lockedWithMultiplier - amountWithMultiplier;
        bal.total = bal.total - amount;
        $.lockedSupply -= amount;
        $.lockedSupplyWithMultiplier -= amountWithMultiplier;

        if (_isRelock || (_address != msg.sender && !$.autoRelockDisabled[_address])) {
            MFDLogic.stakeLogic($, amount, _address, $.defaultLockIndex[_address], true);
        } else {
            if (_doTransfer) {
                IERC20($.stakeToken).safeTransfer(_address, amount);
                emit Withdrawn(_address, amount, $.userBalances[_address].locked, 0, 0, $.stakeToken != $.emissionToken);
            } else {
                revert InvalidAction();
            }
        }
        return amount;
    }

    /// Internal functions

    function _checkNoZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert AddressZero();
    }

    function _checkZeroAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert AmountZero();
    }

    function _setLockTypes(LockType[] memory _lockTypes) internal {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        delete $.lockTypes;
        uint256 len = _lockTypes.length;
        for (uint256 i; i < len;) {
            if (_lockTypes[i].duration == 0) revert InvalidPeriod();
            $.lockTypes.push(_lockTypes[i]);
            unchecked {
                i++;
            }
        }
        emit LockTypesUpdated(_lockTypes);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
