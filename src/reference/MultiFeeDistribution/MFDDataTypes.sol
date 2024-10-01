// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

struct LockedBalance {
    uint256 amount;
    uint256 unlockTime;
    uint256 multiplier;
    uint256 duration;
}

struct EarnedBalance {
    uint256 amount;
    uint256 unlockTime;
    uint256 penalty;
}

struct Reward {
    uint256 periodFinish;
    uint256 rewardPerSecond;
    uint256 lastUpdateTime;
    uint256 rewardPerTokenStored;
    // tracks already-added balances to handle accrued interest in aToken rewards
    // for the stakingToken this value is unused and will always be 0
    uint256 balance;
}

struct Balances {
    uint256 total; // sum of earnings and lockings; no use when LP and RDNT is different
    uint256 unlocked; // RDNT token
    uint256 locked; // LP token or RDNT token
    uint256 lockedWithMultiplier; // Multiplied locked amount
    uint256 earned; // RDNT token
}

struct MultiFeeInitializerParams {
    address emissionToken;
    address lockZap;
    address daoTreasury;
    address priceProvider;
    uint256 rewardDuration;
    uint256 rewardsLookback;
    uint256 lockDuration;
    uint256 burnRatio;
    uint256 vestDuration;
}

struct MultiFeeDistributionStorage {
    /// Addresses
    address bountyManager;
    address daoTreasury;
    address emissionToken;
    address incentivesController;
    address lockZap;
    address operationExpenseReceiver;
    address priceProvider;
    address rewardConverter;
    address stakingToken;
    address starfleetTreasury;
    /// Config
    uint256 burnRatio; // Proportion of burn amount
    uint256 defaultLockDuration; // Duration of lock/earned penalty period, used for earnings
    uint256 operationExpenseRatio; // Reward ratio for operation expenses
    uint256 lockedSupply; // Total locked value
    uint256 lockedSupplyWithMultiplier; // Total locked value including multipliers
    uint256 vestDuration; // Duration of vesting emission token
    uint256[] lockPeriods; // Time lengths for locks
    uint256[] lockMultipliers; // Multipliers for locks
    mapping(address => bool) emissionDistributors; // Addresses approved to call mint
    /// Rewards info
    uint256 rewardDuration; // Duration that rev rewards are streamed over
    uint256 rewardsLookback; // Duration that rewards loop back
    address[] rewardTokens; // Reward tokens being distributed
    mapping(address => bool) isRewardToken; // Stores whether a token is being destibuted to dLP lockers
    mapping(address => Reward) rewardData; // Reward data per token
    /// User info
    mapping(address => Balances) userBalances; // User balances
    mapping(address => LockedBalance[]) userLocks; // User locks
    mapping(address => LockedBalance[]) userEarnings; // User earnings
    mapping(address => uint256) userSlippage; // User's defined max slippage used when performing compound trades
    mapping(address => uint256) defaultLockIndex; // Default lock index for relock
    mapping(address => uint256) lastClaimTime; // Last claim time of the user
    mapping(address => bool) autoRelockDisabled; // User's decision to be `relock` eligible
    mapping(address => bool) autocompoundDisabled; // User's decision to be `autocompound` eligible
    mapping(address => mapping(address => uint256)) userRewardPerTokenPaid; // user -> reward token -> rpt; RPT for paid amount
    mapping(address => mapping(address => uint256)) rewards; // user -> reward token -> amount; used to store reward amount
}
