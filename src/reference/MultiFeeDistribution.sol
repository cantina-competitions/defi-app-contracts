// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {RecoverERC20} from "./helpers/RecoverERC20.sol";
import {IChefIncentivesController} from "../interfaces/radiant/IChefIncentivesController.sol";
import {IBountyManager} from "../interfaces/radiant/IBountyManager.sol";
import {IMultiFeeDistribution, IFeeDistribution} from "../interfaces/radiant/IMultiFeeDistribution.sol";
import {IMintableToken} from "../interfaces/IMintableToken.sol";
import {LockedBalance, Balances, Reward, EarnedBalance} from "../interfaces/radiant/LockedBalance.sol";
import {IPriceProvider} from "../interfaces/radiant/IPriceProvider.sol";

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
    using SafeERC20 for IMintableToken;

    struct MultiFeeInitializerParams {
        address emissionToken;
        address lockZap;
        address daoTreasury;
        address priceProvider;
        uint256 rewardsDuration;
        uint256 rewardsLookback;
        uint256 lockDuration;
        uint256 burnRatio;
        uint256 vestDuration;
    }

    struct MultiFeeDistributionStorage {
        address priceProvider;
        address bountyManager;
        uint256 burn; // Proportion of burn amount
        uint256 rewardsDuration; // Duration that rewards are streamed over
        uint256 rewardsLookback; // Duration that rewards loop back
        uint256 defaultLockDuration; // Duration of lock/earned penalty period, used for earnings
        uint256 vestDuration; // Duration of vesting RDNT
        address rewardConverter; // Returns reward converter
        address incentivesController; // Address of CIC contract
        address emissionToken; // Address of project token
        address stakingToken; // Address of LP token
        address lockZap; // Address of LockZap contract
        address daoTreasury; // DAO wallet
        address starfleetTreasury; // Treasury wallet
        address operationExpenseReceiver; // Operation expenses receiver
        uint256 operationExpenseRatio; // Reward ratio for operation expenses
        uint256 lockedSupply; // Total locked value
        uint256 lockedSupplyWithMultiplier; // Total locked value including multipliers
        uint256[] lockPeriod; // Time lengths for locks
        uint256[] rewardMultipliers; // Multipliers for locks
        address[] rewardTokens; // Reward tokens being distributed
        bool mintersAreSet; // Flag to prevent more minter addings
        mapping(address => bool) isRewardToken; // Stores whether a token is being destibuted to dLP lockers
        mapping(address => Balances) balances;
        mapping(address => LockedBalance[]) userLocks;
        mapping(address => LockedBalance[]) userEarnings;
        mapping(address => uint256) userSlippage; // User's max slippage for each trade when performing compound trades
        mapping(address => uint256) lastAutocompound;
        mapping(address => Reward) rewardData; // Reward data per token
        mapping(address => mapping(address => uint256)) userRewardPerTokenPaid; // user -> reward token -> rpt; RPT for paid amount
        mapping(address => mapping(address => uint256)) rewards; // user -> reward token -> amount; used to store reward amount
        mapping(address => bool) minters; // Addresses approved to call mint
        mapping(address => bool) autoRelockDisabled; // Addresses to relock
        mapping(address => uint256) defaultLockIndex; // Default lock index for relock
        mapping(address => uint256) lastClaimTime; // Last claim time of the user
        mapping(address => bool) autocompoundDisabled;
    }

    /// Constants
    uint256 public constant QUART = 25000; //  25%
    uint256 public constant HALF = 65000; //  65%
    uint256 public constant WHOLE = 100000; // 100%
    uint256 public constant PERCENT_DIVISOR = 10000; // 100%
    uint256 public constant MAX_SLIPPAGE = 9000; // 10% (used for compounding)
    uint256 public constant AGGREGATION_EPOCH = 6 days;
    uint256 public constant RATIO_DIVISOR = 10000;
    uint256 public constant DEFAULT_LOCK_INDEX = 1; // Default lock index

    /// Events
    event Locked(address indexed user, uint256 amount, uint256 lockedBalance, uint256 indexed lockLength, bool isLP);
    event Withdrawn(
        address indexed user, uint256 receivedAmount, uint256 lockedBalance, uint256 penalty, uint256 burn, bool isLP
    );
    event RewardPaid(address indexed user, address indexed rewardToken, uint256 reward);
    event Relocked(address indexed user, uint256 amount, uint256 lockIndex);
    event BountyManagerUpdated(address indexed _bounty);
    event RewardConverterUpdated(address indexed _rewardConverter);
    event LockTypeInfoUpdated(uint256[] lockPeriod, uint256[] rewardMultipliers);
    event AddressesUpdated(IChefIncentivesController _controller, address indexed _treasury);
    event LPTokenUpdated(address indexed _stakingToken);
    event RewardAdded(address indexed _rewardToken);
    event LockerAdded(address indexed locker);
    event LockerRemoved(address indexed locker);
    event RevenueEarned(address indexed asset, uint256 assetAmount);
    event OperationExpensesUpdated(address indexed _operationExpenses, uint256 _operationExpenseRatio);
    event NewTransferAdded(address indexed asset, uint256 lpUsdValue);
    event UserAutocompoundUpdated(address indexed user, bool indexed disabled);
    event UserSlippageUpdated(address indexed user, uint256 slippage);

    /// Custom Errors
    error AddressZero();
    error AmountZero();
    error InvalidBurn();
    error InvalidRatio();
    error InvalidLookback();
    error InvalidLockPeriod();
    error InsufficientPermission();
    error AlreadyAdded();
    error AlreadySet();
    error InvalidType();
    error ActiveReward();
    error InvalidAmount();
    error InvalidEarned();
    error InvalidTime();
    error InvalidPeriod();
    error UnlockTimeNotFound();
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
     *  First reward MUST be the RDNT token or things will break
     *  related to the 50% penalty and distribution to locked balances.
     * @param initParams MultiFeeInitializerParams
     * - emissionToken RDNT token address
     * - lockZap LockZap contract address
     * - daoTreasury DAO address
     * - priceProvider PriceProvider contract address
     * - rewardsDuration Duration that rewards are streamed over
     * - rewardsLookback Duration that rewards loop back
     * - lockDuration lock duration
     * - burnRatio Proportion of burn amount
     * - vestDuration vest duration
     */
    function initialize(MultiFeeInitializerParams calldata initParams) public initializer {
        if (initParams.emissionToken == address(0)) revert AddressZero();
        if (initParams.lockZap == address(0)) revert AddressZero();
        if (initParams.daoTreasury == address(0)) revert AddressZero();
        if (initParams.priceProvider == address(0)) revert AddressZero();
        if (initParams.rewardsDuration == uint256(0)) revert AmountZero();
        if (initParams.rewardsLookback == uint256(0)) revert AmountZero();
        if (initParams.lockDuration == uint256(0)) revert AmountZero();
        if (initParams.vestDuration == uint256(0)) revert AmountZero();
        if (initParams.burnRatio > WHOLE) revert InvalidBurn();
        if (initParams.rewardsLookback > initParams.rewardsDuration) revert InvalidLookback();

        __Ownable_init(_msgSender());
        __Pausable_init();

        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();

        $.emissionToken = initParams.emissionToken;
        $.lockZap = initParams.lockZap;
        $.daoTreasury = initParams.daoTreasury;
        $.priceProvider = initParams.priceProvider;
        $.rewardTokens.push(initParams.emissionToken);
        $.rewardData[initParams.emissionToken].lastUpdateTime = block.timestamp;
        $.rewardsDuration = initParams.rewardsDuration;
        $.rewardsLookback = initParams.rewardsLookback;
        $.defaultLockDuration = initParams.lockDuration;
        $.burn = initParams.burnRatio;
        $.vestDuration = initParams.vestDuration;
    }

    /// View functions

    /**
     * @notice Return emission token.
     */
    function emissionToken() external view returns (IMintableToken) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return IMintableToken($.emissionToken);
    }

    /**
     * @notice Return staking token.
     */
    function stakingToken() external view returns (address) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.stakingToken;
    }

    /**
     * @notice Return lock durations.
     */
    function getLockDurations() external view returns (uint256[] memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.lockPeriod;
    }

    /**
     * @notice Return reward multipliers.
     */
    function getLockMultipliers() external view returns (uint256[] memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.rewardMultipliers;
    }

    /**
     * @notice Returns all locks of `_user`.
     */
    function lockInfo(address _user) external view returns (LockedBalance[] memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.userLocks[_user];
    }

    /**
     * @notice Returns the default lock index for `_user`.
     */
    function defaultLockIndex(address _user) external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.defaultLockIndex[_user];
    }

    /**
     * @notice Total balance of a `_user`, including unlocked, locked and earned tokens.
     */
    function totalBalance(address _user) external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if ($.stakingToken == $.emissionToken) {
            return $.balances[_user].total;
        }
        return $.balances[_user].locked;
    }

    /**
     * @notice Returns price provider address
     */
    function getPriceProvider() external view returns (address) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.priceProvider;
    }

    /**
     * @notice Returns the daoTreasury address.
     */
    function daoTreasury() external view returns (address) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.daoTreasury;
    }

    /**
     * @notice Returns the `_rewardToken` amount estimated for the `rewardsDuration` period.
     */
    function getRewardForDuration(address _rewardToken) external view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return ($.rewardData[_rewardToken].rewardPerSecond * $.rewardsDuration) / 1e12;
    }

    /**
     * @notice Returns balances of  `_user`.
     */
    function getBalances(address _user) external view returns (Balances memory) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return $.balances[_user];
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
     * @notice Reward locked amount of the user.
     * @param _user address
     * @return locked amount
     */
    function lockedBalance(address _user) public view returns (uint256 locked) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        LockedBalance[] storage locks = $.userLocks[_user];
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
     * @notice Returns reward applicable timestamp.
     * @param _rewardToken for the reward
     * @return end time of reward period
     */
    function lastTimeRewardApplicable(address _rewardToken) public view returns (uint256) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 periodFinish = $.rewardData[_rewardToken].periodFinish;
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Information on a user's lockings
     * @return total balance of locks
     * @return unlockable balance
     * @return locked balance
     * @return lockedWithMultiplier
     * @return lockData which is an array of locks
     */
    function lockedBalances(address user)
        public
        view
        returns (
            uint256 total,
            uint256 unlockable,
            uint256 locked,
            uint256 lockedWithMultiplier,
            LockedBalance[] memory lockData
        )
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        LockedBalance[] storage locks = $.userLocks[user];
        uint256 idx;
        uint256 length = locks.length;
        for (uint256 i; i < length;) {
            if (locks[i].unlockTime > block.timestamp) {
                if (idx == 0) {
                    lockData = new LockedBalance[](locks.length - i);
                }
                lockData[idx] = locks[i];
                idx++;
                locked = locked + locks[i].amount;
                lockedWithMultiplier = lockedWithMultiplier + (locks[i].amount * locks[i].multiplier);
            } else {
                unlockable = unlockable + locks[i].amount;
            }
            unchecked {
                i++;
            }
        }
        total = $.balances[user].locked;
    }

    /**
     * @notice Earnings which are vesting, and earnings which have vested for full duration.
     * @dev Earned balances may be withdrawn immediately, but will incur a penalty between 25-90%, based on a linear schedule of elapsed time.
     * @return totalVesting sum of vesting tokens
     * @return unlocked earnings
     * @return earningsData which is an array of all infos
     */
    function earnedBalances(address _user)
        public
        view
        returns (uint256 totalVesting, uint256 unlocked, EarnedBalance[] memory earningsData)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        unlocked = $.balances[_user].unlocked;
        LockedBalance[] storage earnings = $.userEarnings[_user];
        uint256 idx;
        uint256 length = earnings.length;
        uint256 currentTimestamp = block.timestamp;
        for (uint256 i; i < length;) {
            if (earnings[i].unlockTime > currentTimestamp) {
                if (idx == 0) {
                    earningsData = new EarnedBalance[](earnings.length - i);
                }
                (, uint256 penaltyAmount,,) = _ieeWithdrawableBalance(_user, earnings[i].unlockTime);
                earningsData[idx].amount = earnings[i].amount;
                earningsData[idx].unlockTime = earnings[i].unlockTime;
                earningsData[idx].penalty = penaltyAmount;
                idx++;
                totalVesting = totalVesting + earnings[i].amount;
            } else {
                unlocked = unlocked + earnings[i].amount;
            }
            unchecked {
                i++;
            }
        }
        return (totalVesting, unlocked, earningsData);
    }

    /**
     * @notice Final balance received and penalty balance paid by user upon calling exit.
     * @dev This is earnings, not locks.
     * @param _user address.
     * @return amount total withdrawable amount.
     * @return penaltyAmount penalty amount.
     * @return burnAmount amount to burn.
     */
    function withdrawableBalance(address _user)
        public
        view
        returns (uint256 amount, uint256 penaltyAmount, uint256 burnAmount)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 earned = $.balances[_user].earned;
        if (earned > 0) {
            uint256 length = $.userEarnings[_user].length;
            for (uint256 i; i < length;) {
                uint256 earnedAmount = $.userEarnings[_user][i].amount;
                if (earnedAmount == 0) continue;
                (,, uint256 newPenaltyAmount, uint256 newBurnAmount) = _penaltyInfo($.userEarnings[_user][i]);
                penaltyAmount = penaltyAmount + newPenaltyAmount;
                burnAmount = burnAmount + newBurnAmount;
                unchecked {
                    i++;
                }
            }
        }
        amount = $.balances[_user].unlocked + earned - penaltyAmount;
        return (amount, penaltyAmount, burnAmount);
    }

    /**
     * @notice Reward amount per token
     * @dev Reward is distributed only for locks.
     * @param _rewardToken for reward
     * @return rptStored current RPT with accumulated rewards
     */
    function rewardPerToken(address _rewardToken) public view returns (uint256 rptStored) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        rptStored = $.rewardData[_rewardToken].rewardPerTokenStored;
        if ($.lockedSupplyWithMultiplier > 0) {
            uint256 newReward = (lastTimeRewardApplicable(_rewardToken) - $.rewardData[_rewardToken].lastUpdateTime)
                * $.rewardData[_rewardToken].rewardPerSecond;
            rptStored = rptStored + ((newReward * 1e18) / $.lockedSupplyWithMultiplier);
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
            rewardsData[i].amount = _earned(
                _account,
                rewardsData[i].token,
                $.balances[_account].lockedWithMultiplier,
                rewardPerToken(rewardsData[i].token)
            ) / 1e12;
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

        (, uint256 unlockable,,,) = lockedBalances(_user);
        if (unlockable == 0) {
            return (false);
        } else {
            issueBaseBounty = true;
        }

        if (!_execute) {
            return (issueBaseBounty);
        }
        // Withdraw the user's expried locks
        _withdrawExpiredLocksFor(_user, false, true, $.userLocks[_user].length);
    }

    /**
     * @notice Claim all pending staking rewards.
     * @param _rewardTokens array of reward tokens
     */
    function getReward(address[] memory _rewardTokens) public {
        _updateReward(msg.sender);
        _getReward(msg.sender, _rewardTokens);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        IPriceProvider($.priceProvider).update();
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

    /**
     * @notice Requalify user for reward elgibility
     * @param _user address
     */
    function requalifyFor(address _user) public {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        IChefIncentivesController($.incentivesController).afterLockUpdate(_user);
    }

    /// Setters

    /**
     * @notice Set minters
     * @param minters_ array of address
     */
    function setMinters(address[] calldata minters_) external onlyOwner {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 length = minters_.length;
        for (uint256 i; i < length;) {
            if (minters_[i] == address(0)) revert AddressZero();
            $.minters[minters_[i]] = true;
            unchecked {
                i++;
            }
        }
        $.mintersAreSet = true;
    }

    /**
     * @notice Sets bounty manager contract.
     * @param _bountyManager contract address
     */
    function setBountyManager(address _bountyManager) external onlyOwner {
        if (_bountyManager == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.bountyManager = _bountyManager;
        $.minters[_bountyManager] = true;
        emit BountyManagerUpdated(_bountyManager);
    }

    /**
     * @notice Sets reward converter contract.
     * @param _rewardConverter contract address
     */
    function addRewardConverter(address _rewardConverter) external onlyOwner {
        if (_rewardConverter == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.rewardConverter = _rewardConverter;
        emit RewardConverterUpdated(_rewardConverter);
    }

    /**
     * @notice Sets lock period and reward multipliers.
     * @param _lockPeriod lock period array
     * @param _rewardMultipliers multipliers per lock period
     */
    function setLockTypeInfo(uint256[] calldata _lockPeriod, uint256[] calldata _rewardMultipliers)
        external
        onlyOwner
    {
        if (_lockPeriod.length != _rewardMultipliers.length) revert InvalidLockPeriod();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        delete $.lockPeriod;
        delete $.rewardMultipliers;
        uint256 length = _lockPeriod.length;
        for (uint256 i; i < length;) {
            $.lockPeriod.push($.lockPeriod[i]);
            $.rewardMultipliers.push($.rewardMultipliers[i]);
            unchecked {
                i++;
            }
        }
        emit LockTypeInfoUpdated(_lockPeriod, _rewardMultipliers);
    }

    /**
     * @notice Set CIC, MFD and Treasury.
     * @param _controller CIC address
     * @param _treasury address
     */
    function setAddresses(IChefIncentivesController _controller, address _treasury) external onlyOwner {
        if (address(_controller) == address(0)) revert AddressZero();
        if (address(_treasury) == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.incentivesController = address(_controller);
        $.starfleetTreasury = _treasury;
        emit AddressesUpdated(_controller, _treasury);
    }

    /**
     * @notice Set LP token.
     * @param _stakingToken LP token address
     */
    function setLPToken(address _stakingToken) external onlyOwner {
        if (_stakingToken == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if ($.stakingToken != address(0)) revert AlreadySet();
        $.stakingToken = _stakingToken;
        emit LPTokenUpdated(_stakingToken);
    }

    /**
     * @notice Add a new reward token to be distributed to stakers.
     * @param _rewardToken address
     */
    function addReward(address _rewardToken) external {
        if (_rewardToken == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (!$.minters[msg.sender]) revert InsufficientPermission();
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
        if (!$.minters[msg.sender]) revert InsufficientPermission();

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
        if (_index >= $.lockPeriod.length) revert InvalidType();
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
     * @notice Set what slippage to use for tokens traded during the auto compound process on behalf of the user
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
        if (_lookback == uint256(0)) revert AmountZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_lookback > $.rewardsDuration) revert InvalidLookback();
        $.rewardsLookback = _lookback;
        // TODO add event here
    }

    /**
     * @notice Set operation expenses account
     * @param _operationExpenseReceiver Address to receive operation expenses
     * @param _operationExpenseRatio Proportion of operation expense
     */
    function setOperationExpenses(address _operationExpenseReceiver, uint256 _operationExpenseRatio)
        external
        onlyOwner
    {
        if (_operationExpenseRatio > RATIO_DIVISOR) revert InvalidRatio();
        if (_operationExpenseReceiver == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        $.operationExpenseReceiver = _operationExpenseReceiver;
        $.operationExpenseRatio = _operationExpenseRatio;
        emit OperationExpensesUpdated(_operationExpenseReceiver, _operationExpenseRatio);
    }

    /// External functions

    /**
     * @notice Stake tokens to receive rewards.
     * @dev Locked tokens cannot be withdrawn for defaultLockDuration and are eligible to receive rewards.
     * @param _amount to stake.
     * @param _onBehalfOf address for staking.
     * @param _typeIndex lock type index.
     */
    function stake(uint256 _amount, address _onBehalfOf, uint256 _typeIndex) external {
        _stake(_amount, _onBehalfOf, _typeIndex, false);
    }

    /**
     * @notice Add to earnings
     * @dev Minted tokens receive rewards normally but incur a 50% penalty when
     *  withdrawn before vestDuration has passed.
     * @param user vesting owner.
     * @param amount to vest.
     * @param withPenalty does this bear penalty?
     */
    function vestTokens(address user, uint256 amount, bool withPenalty) external whenNotPaused {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (!$.minters[msg.sender]) revert InsufficientPermission();
        if (amount == 0) return;

        if (user == address(this)) {
            // minting to this contract adds the new tokens as incentives for lockers
            _notifyReward(address($.emissionToken), amount);
            return;
        }

        Balances storage bal = $.balances[user];
        bal.total = bal.total + amount;
        if (withPenalty) {
            bal.earned = bal.earned + amount;
            LockedBalance[] storage earnings = $.userEarnings[user];

            uint256 currentDay = block.timestamp / 1 days;
            uint256 lastIndex = earnings.length > 0 ? earnings.length - 1 : 0;
            uint256 vestingDurationDays = $.vestDuration / 1 days;

            // We check if an entry for the current day already exists. If yes, add new amount to that entry
            if (earnings.length > 0 && (earnings[lastIndex].unlockTime / 1 days) == currentDay + vestingDurationDays) {
                earnings[lastIndex].amount = earnings[lastIndex].amount + amount;
            } else {
                // If there is no entry for the current day, create a new one
                uint256 unlockTime = block.timestamp + $.vestDuration;
                earnings.push(
                    LockedBalance({amount: amount, unlockTime: unlockTime, multiplier: 1, duration: $.vestDuration})
                );
            }
        } else {
            bal.unlocked = bal.unlocked + amount;
        }
    }

    /**
     * @notice Withdraw tokens from earnings and unlocked.
     * @dev First withdraws unlocked tokens, then earned tokens. Withdrawing earned tokens
     *  incurs a 50% penalty which is distributed based on locked balances.
     * @param _amount for withdraw
     */
    function withdraw(uint256 _amount) external {
        if (_amount == 0) revert AmountZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();

        uint256 penaltyAmount;
        uint256 burnAmount;
        Balances storage bal = $.balances[msg.sender];

        if (_amount <= bal.unlocked) {
            bal.unlocked = bal.unlocked - _amount;
        } else {
            uint256 remaining = _amount - bal.unlocked;
            if (bal.earned < remaining) revert InvalidEarned();
            bal.unlocked = 0;
            uint256 sumEarned = bal.earned;
            uint256 i;
            for (i = 0;;) {
                uint256 earnedAmount = $.userEarnings[msg.sender][i].amount;
                if (earnedAmount == 0) continue;
                (uint256 withdrawAmount, uint256 penaltyFactor, uint256 newPenaltyAmount, uint256 newBurnAmount) =
                    _penaltyInfo($.userEarnings[msg.sender][i]);

                uint256 requiredAmount = earnedAmount;
                if (remaining >= withdrawAmount) {
                    remaining = remaining - withdrawAmount;
                    if (remaining == 0) i++;
                } else {
                    requiredAmount = (remaining * WHOLE) / (WHOLE - penaltyFactor);
                    $.userEarnings[msg.sender][i].amount = earnedAmount - requiredAmount;
                    remaining = 0;

                    newPenaltyAmount = (requiredAmount * penaltyFactor) / WHOLE;
                    newBurnAmount = (newPenaltyAmount * $.burn) / WHOLE;
                }
                sumEarned = sumEarned - requiredAmount;

                penaltyAmount = penaltyAmount + newPenaltyAmount;
                burnAmount = burnAmount + newBurnAmount;

                if (remaining == 0) {
                    break;
                } else {
                    if (sumEarned == 0) revert InvalidEarned();
                }
                unchecked {
                    i++;
                }
            }
            if (i > 0) {
                uint256 length = $.userEarnings[msg.sender].length;
                for (uint256 j = i; j < length;) {
                    $.userEarnings[msg.sender][j - i] = $.userEarnings[msg.sender][j];
                    unchecked {
                        j++;
                    }
                }
                for (uint256 j = 0; j < i;) {
                    $.userEarnings[msg.sender].pop();
                    unchecked {
                        j++;
                    }
                }
            }
            bal.earned = sumEarned;
        }

        // Update values
        bal.total = bal.total - _amount - penaltyAmount;
        _withdrawTokens(msg.sender, _amount, penaltyAmount, burnAmount, false);
    }

    /**
     * @notice Withdraw individual unlocked balance and earnings, optionally claim pending rewards.
     * @param _claimRewards true to claim rewards when exit
     * @param _unlockTime of earning
     */
    function individualEarlyExit(bool _claimRewards, uint256 _unlockTime) external {
        address onBehalfOf = msg.sender;
        if (_unlockTime <= block.timestamp) revert InvalidTime();
        (uint256 amount, uint256 penaltyAmount, uint256 burnAmount, uint256 index) =
            _ieeWithdrawableBalance(onBehalfOf, _unlockTime);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();

        uint256 length = $.userEarnings[onBehalfOf].length;
        for (uint256 i = index + 1; i < length;) {
            $.userEarnings[onBehalfOf][i - 1] = $.userEarnings[onBehalfOf][i];
            unchecked {
                i++;
            }
        }
        $.userEarnings[onBehalfOf].pop();

        Balances storage bal = $.balances[onBehalfOf];
        bal.total = bal.total - amount - penaltyAmount;
        bal.earned = bal.earned - amount - penaltyAmount;

        _withdrawTokens(onBehalfOf, amount, penaltyAmount, burnAmount, _claimRewards);
    }

    /**
     * @notice Withdraw full unlocked balance and earnings, optionally claim pending rewards.
     * @param _claimRewards true to claim rewards when exit
     */
    function exit(bool _claimRewards) external {
        address onBehalfOf = msg.sender;
        (uint256 amount, uint256 penaltyAmount, uint256 burnAmount) = withdrawableBalance(onBehalfOf);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();

        delete $.userEarnings[onBehalfOf];

        Balances storage bal = $.balances[onBehalfOf];
        bal.total = bal.total - bal.unlocked - bal.earned;
        bal.unlocked = 0;
        bal.earned = 0;

        _withdrawTokens(onBehalfOf, amount, penaltyAmount, burnAmount, _claimRewards);
    }

    /**
     * @notice Claim all pending staking rewards.
     */
    function getAllRewards() external {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        return getReward($.rewardTokens);
    }

    /**
     * @notice Withdraw expired locks with options
     * @param _address for withdraw
     * @param _limit of lock length for withdraw
     * @param _isRelockAction option to relock
     * @return withdraw amount
     */
    function withdrawExpiredLocksForWithOptions(address _address, uint256 _limit, bool _isRelockAction)
        external
        returns (uint256)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_limit == 0) _limit = $.userLocks[_address].length;

        return _withdrawExpiredLocksFor(_address, _isRelockAction, true, _limit);
    }

    /**
     * @notice Zap vesting RDNT tokens to LP
     * @param _user address
     * @return zapped amount
     */
    function zapVestingToLp(address _user) external returns (uint256 zapped) {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (msg.sender != $.lockZap) revert InsufficientPermission();

        _updateReward(_user);

        uint256 currentTimestamp = block.timestamp;
        LockedBalance[] storage earnings = $.userEarnings[_user];
        for (uint256 i = earnings.length; i > 0;) {
            if (earnings[i - 1].unlockTime > currentTimestamp) {
                zapped = zapped + earnings[i - 1].amount;
                earnings.pop();
            } else {
                break;
            }
            unchecked {
                i--;
            }
        }

        IERC20($.emissionToken).safeTransfer($.lockZap, zapped);

        Balances storage bal = $.balances[_user];
        bal.earned = bal.earned - zapped;
        bal.total = bal.total - zapped;

        IPriceProvider($.priceProvider).update();

        return zapped;
    }

    /**
     * @notice Claim rewards by converter.
     * @dev Rewards are transfered to converter. In the Radiant Capital protocol
     * 		the role of the Converter is taken over by Compounder.sol.
     * @param _onBehalf address to claim.
     */
    function claimFromConverter(address _onBehalf) external whenNotPaused {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (msg.sender != $.rewardConverter) revert InsufficientPermission();
        _updateReward(_onBehalf);
        uint256 length = $.rewardTokens.length;
        for (uint256 i; i < length;) {
            address token = $.rewardTokens[i];
            if (token != $.emissionToken) {
                _notifyUnseenReward(token);
                uint256 reward = $.rewards[_onBehalf][token] / 1e12;
                if (reward > 0) {
                    $.rewards[_onBehalf][token] = 0;
                    $.rewardData[token].balance = $.rewardData[token].balance - reward;

                    IERC20(token).safeTransfer($.rewardConverter, reward);
                    emit RewardPaid(_onBehalf, token, reward);
                }
            }
            unchecked {
                i++;
            }
        }
        IPriceProvider($.priceProvider).update();
        $.lastClaimTime[_onBehalf] = block.timestamp;
    }

    /**
     * @notice Withdraw and restake assets.
     */
    function relock() external virtual {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 amount = _withdrawExpiredLocksFor(msg.sender, true, true, $.userLocks[msg.sender].length);
        emit Relocked(msg.sender, amount, $.defaultLockIndex[msg.sender]);
    }

    /**
     * @notice Requalify user
     */
    function requalify() external {
        requalifyFor(msg.sender);
    }

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
     * @notice Stake tokens to receive rewards.
     * @dev Locked tokens cannot be withdrawn for defaultLockDuration and are eligible to receive rewards.
     * @param _amount to stake.
     * @param _onBehalfOf address for staking.
     * @param _typeIndex lock type index.
     * @param _isRelock true if this is with relock enabled.
     */
    function _stake(uint256 _amount, address _onBehalfOf, uint256 _typeIndex, bool _isRelock) internal whenNotPaused {
        if (_amount == 0) return;
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if ($.bountyManager != address(0)) {
            if (_amount < IBountyManager($.bountyManager).minDLPBalance()) revert InvalidAmount();
        }
        if (_typeIndex >= $.lockPeriod.length) revert InvalidType();

        _updateReward(_onBehalfOf);

        LockedBalance[] memory userLocks = $.userLocks[_onBehalfOf];
        uint256 userLocksLength = userLocks.length;

        Balances storage bal = $.balances[_onBehalfOf];
        bal.total = bal.total + _amount;

        bal.locked = bal.locked + _amount;
        $.lockedSupply += _amount;

        {
            uint256 rewardMultiplier = $.rewardMultipliers[_typeIndex];
            bal.lockedWithMultiplier = bal.lockedWithMultiplier + (_amount * rewardMultiplier);
            $.lockedSupplyWithMultiplier += (_amount * rewardMultiplier);
        }

        uint256 lockIndex;
        LockedBalance memory newLock;
        {
            uint256 lockDurationWeeks = $.lockPeriod[_typeIndex] / AGGREGATION_EPOCH;
            uint256 unlockTime = block.timestamp + (lockDurationWeeks * AGGREGATION_EPOCH);
            lockIndex = _binarySearch(userLocks, userLocksLength, unlockTime);
            newLock = LockedBalance({
                amount: _amount,
                unlockTime: unlockTime,
                multiplier: $.rewardMultipliers[_typeIndex],
                duration: $.lockPeriod[_typeIndex]
            });
        }

        if (userLocksLength > 0) {
            uint256 indexToAggregate = lockIndex == 0 ? 0 : lockIndex - 1;
            if (
                (indexToAggregate < userLocksLength)
                    && (
                        userLocks[indexToAggregate].unlockTime / AGGREGATION_EPOCH == newLock.unlockTime / AGGREGATION_EPOCH
                    ) && (userLocks[indexToAggregate].multiplier == $.rewardMultipliers[_typeIndex])
            ) {
                $.userLocks[_onBehalfOf][indexToAggregate].amount = userLocks[indexToAggregate].amount + _amount;
            } else {
                _insertLock(_onBehalfOf, newLock, lockIndex, userLocksLength);
                emit LockerAdded(_onBehalfOf);
            }
        } else {
            _insertLock(_onBehalfOf, newLock, lockIndex, userLocksLength);
            emit LockerAdded(_onBehalfOf);
        }

        if (!_isRelock) {
            IERC20($.stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
        }

        IChefIncentivesController($.incentivesController).afterLockUpdate(_onBehalfOf);
        emit Locked(
            _onBehalfOf,
            _amount,
            $.balances[_onBehalfOf].locked,
            $.lockPeriod[_typeIndex],
            $.stakingToken != $.emissionToken
        );
    }

    /**
     * @notice Update user reward info.
     * @param _account address
     */
    function _updateReward(address _account) internal {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 balance = $.balances[_account].lockedWithMultiplier;
        uint256 length = $.rewardTokens.length;
        for (uint256 i = 0; i < length;) {
            address token = $.rewardTokens[i];
            uint256 rpt = rewardPerToken(token);

            Reward storage r = $.rewardData[token];
            r.rewardPerTokenStored = rpt;
            r.lastUpdateTime = lastTimeRewardApplicable(token);

            if (_account != address(this)) {
                $.rewards[_account][token] = _earned(_account, token, balance, rpt);
                $.userRewardPerTokenPaid[_account][token] = rpt;
            }
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Add new reward.
     * @dev If prev reward period is not done, then it resets `rewardPerSecond` and restarts period
     * @param _rewardToken address
     * @param _reward amount
     */
    function _notifyReward(address _rewardToken, uint256 _reward) internal {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
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
            r.rewardPerSecond = (_reward * 1e12) / $.rewardsDuration;
        } else {
            uint256 remaining = r.periodFinish - block.timestamp;
            uint256 leftover = (remaining * r.rewardPerSecond) / 1e12;
            r.rewardPerSecond = ((_reward + leftover) * 1e12) / $.rewardsDuration;
        }

        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + $.rewardsDuration;
        r.balance = r.balance + _reward;

        emit RevenueEarned(_rewardToken, _reward);
        uint256 lpUsdValue = IPriceProvider($.priceProvider).getRewardTokenPrice(_rewardToken, _reward);
        emit NewTransferAdded(_rewardToken, lpUsdValue);
    }

    /**
     * @notice Notify unseen rewards.
     * @dev for rewards other than RDNT token, every 24 hours we check if new
     *  rewards were sent to the contract or accrued via aToken interest.
     * @param token address
     */
    function _notifyUnseenReward(address token) internal {
        if (token == address(0)) revert AddressZero();
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (token == $.emissionToken) {
            return;
        }
        Reward storage r = $.rewardData[token];
        uint256 periodFinish = r.periodFinish;
        if (periodFinish == 0) revert InvalidPeriod();
        if (periodFinish < block.timestamp + $.rewardsDuration - $.rewardsLookback) {
            uint256 unseen = IERC20(token).balanceOf(address(this)) - r.balance;
            if (unseen > 0) {
                _notifyReward(token, unseen);
            }
        }
    }

    /**
     * @notice User gets reward
     * @param _user address
     * @param _rewardTokens array of reward tokens
     */
    function _getReward(address _user, address[] memory _rewardTokens) internal whenNotPaused {
        uint256 length = _rewardTokens.length;
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        IChefIncentivesController chefIncentivesController = IChefIncentivesController($.incentivesController);
        chefIncentivesController.setEligibilityExempt(_user, true);
        for (uint256 i; i < length;) {
            address token = _rewardTokens[i];
            _notifyUnseenReward(token);
            uint256 reward = $.rewards[_user][token] / 1e12;
            if (reward > 0) {
                $.rewards[_user][token] = 0;
                $.rewardData[token].balance = $.rewardData[token].balance - reward;

                IERC20(token).safeTransfer(_user, reward);
                emit RewardPaid(_user, token, reward);
            }
            unchecked {
                i++;
            }
        }
        chefIncentivesController.setEligibilityExempt(_user, false);
        chefIncentivesController.afterLockUpdate(_user);
    }

    /**
     * @notice Withdraw tokens from MFD
     * @param _onBehalfOf address to withdraw
     * @param _amount of withdraw
     * @param _penaltyAmount penalty applied amount
     * @param _burnAmount amount to burn
     * @param _claimRewards option to claim rewards
     */
    function _withdrawTokens(
        address _onBehalfOf,
        uint256 _amount,
        uint256 _penaltyAmount,
        uint256 _burnAmount,
        bool _claimRewards
    ) internal {
        if (_onBehalfOf != msg.sender) revert InsufficientPermission();
        _updateReward(_onBehalfOf);
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        IERC20($.emissionToken).safeTransfer(_onBehalfOf, _amount);
        if (_penaltyAmount > 0) {
            if (_burnAmount > 0) {
                IERC20($.emissionToken).safeTransfer($.starfleetTreasury, _burnAmount);
            }
            IERC20($.emissionToken).safeTransfer($.daoTreasury, _penaltyAmount - _burnAmount);
        }

        if (_claimRewards) {
            _getReward(_onBehalfOf, $.rewardTokens);
            $.lastClaimTime[_onBehalfOf] = block.timestamp;
        }

        IPriceProvider($.priceProvider).update();

        emit Withdrawn(_onBehalfOf, _amount, $.balances[_onBehalfOf].locked, _penaltyAmount, _burnAmount, false);
    }

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
        LockedBalance[] storage locks = $.userLocks[_user];

        if (locks.length != 0) {
            uint256 length = locks.length <= _limit ? locks.length : _limit;
            uint256 i;
            while (i < length && locks[i].unlockTime <= block.timestamp) {
                lockAmount = lockAmount + locks[i].amount;
                lockAmountWithMultiplier = lockAmountWithMultiplier + (locks[i].amount * locks[i].multiplier);
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
     * @notice Withdraw all currently locked tokens where the unlock time has passed.
     * @param _address of the user.
     * @param _isRelockAction true if withdraw with relock
     * @param _doTransfer true to transfer tokens to user
     * @param _limit limit for looping operation
     * @return amount for withdraw
     */
    function _withdrawExpiredLocksFor(address _address, bool _isRelockAction, bool _doTransfer, uint256 _limit)
        internal
        whenNotPaused
        returns (uint256 amount)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        if (_isRelockAction && _address != msg.sender && $.lockZap != msg.sender) revert InsufficientPermission();
        _updateReward(_address);

        uint256 amountWithMultiplier;
        Balances storage bal = $.balances[_address];
        (amount, amountWithMultiplier) = _cleanWithdrawableLocks(_address, _limit);
        bal.locked = bal.locked - amount;
        bal.lockedWithMultiplier = bal.lockedWithMultiplier - amountWithMultiplier;
        bal.total = bal.total - amount;
        $.lockedSupply -= amount;
        $.lockedSupplyWithMultiplier -= amountWithMultiplier;

        if (_isRelockAction || (_address != msg.sender && !$.autoRelockDisabled[_address])) {
            _stake(amount, _address, $.defaultLockIndex[_address], true);
        } else {
            if (_doTransfer) {
                IERC20($.stakingToken).safeTransfer(_address, amount);
                IChefIncentivesController($.incentivesController).afterLockUpdate(_address);
                emit Withdrawn(_address, amount, $.balances[_address].locked, 0, 0, $.stakingToken != $.emissionToken);
            } else {
                revert InvalidAction();
            }
        }
        return amount;
    }

    /**
     * Internal View functions **********************
     */

    /**
     * @notice Returns withdrawable balance at exact unlock time
     * @param _user address for withdraw
     * @param _unlockTime exact unlock time
     * @return amount total withdrawable amount
     * @return penaltyAmount penalty amount
     * @return burnAmount amount to burn
     * @return index of earning
     */
    function _ieeWithdrawableBalance(address _user, uint256 _unlockTime)
        internal
        view
        returns (uint256 amount, uint256 penaltyAmount, uint256 burnAmount, uint256 index)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        uint256 length = $.userEarnings[_user].length;
        for (index; index < length;) {
            if ($.userEarnings[_user][index].unlockTime == _unlockTime) {
                (amount,, penaltyAmount, burnAmount) = _penaltyInfo($.userEarnings[_user][index]);
                return (amount, penaltyAmount, burnAmount, index);
            }
            unchecked {
                index++;
            }
        }
        revert UnlockTimeNotFound();
    }

    /**
     * @notice Add new lockings
     * @dev We keep the array to be sorted by unlock time.
     * @param user address to insert lock for.
     * @param newLock new lock info.
     * @param index of where to store the new lock.
     * @param lockLength length of the lock array.
     */
    function _insertLock(address user, LockedBalance memory newLock, uint256 index, uint256 lockLength) internal {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
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
     * @notice Calculate earnings.
     * @param _user address of earning owner
     * @param _rewardToken address
     * @param _balance of the user
     * @param _currentRewardPerToken current RPT
     * @return earnings amount
     */
    function _earned(address _user, address _rewardToken, uint256 _balance, uint256 _currentRewardPerToken)
        internal
        view
        returns (uint256 earnings)
    {
        MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
        earnings = $.rewards[_user][_rewardToken];
        uint256 realRPT = _currentRewardPerToken - $.userRewardPerTokenPaid[_user][_rewardToken];
        earnings = earnings + ((_balance * realRPT) / 1e18);
    }

    /**
     * @notice Penalty information of individual earning
     * @param _earning earning info.
     * @return amount of available earning.
     * @return penaltyFactor penalty rate.
     * @return penaltyAmount amount of penalty.
     * @return burnAmount amount to burn.
     */
    function _penaltyInfo(LockedBalance memory _earning)
        internal
        view
        returns (uint256 amount, uint256 penaltyFactor, uint256 penaltyAmount, uint256 burnAmount)
    {
        if (_earning.unlockTime > block.timestamp) {
            // 90% on day 1, decays to 25% on day 90
            MultiFeeDistributionStorage storage $ = _getMultiFeeDistributionStorage();
            penaltyFactor = ((_earning.unlockTime - block.timestamp) * HALF) / $.vestDuration + QUART; // 25% + timeLeft/vestDuration * 65%
            penaltyAmount = (_earning.amount * penaltyFactor) / WHOLE;
            burnAmount = (penaltyAmount * $.burn) / WHOLE;
        }
        amount = _earning.amount - penaltyAmount;
    }

    /// Private functions
    function _binarySearch(LockedBalance[] memory locks, uint256 length, uint256 unlockTime)
        private
        pure
        returns (uint256)
    {
        uint256 low = 0;
        uint256 high = length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (locks[mid].unlockTime < unlockTime) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
