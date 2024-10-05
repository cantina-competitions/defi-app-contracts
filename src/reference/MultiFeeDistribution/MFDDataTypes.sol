// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

struct LockType {
    uint128 duration;
    uint128 multiplier;
}

struct StakedLock {
    uint256 amount;
    uint256 unlockTime;
    uint256 multiplier;
    uint256 duration;
}

struct Reward {
    uint256 periodFinish;
    uint256 rewardPerSecond;
    uint256 lastUpdateTime;
    uint256 rewardPerTokenStored;
    // tracks already-added balances to handle accrued interest in aToken rewards
    // for the stakeToken this value is unused and will always be 0
    uint256 balance;
}

struct Balances {
    uint256 total; // total staked tokens
    uint256 locked; // locked staked tokens
    uint256 unlocked; // unlocked stake tokens
    uint256 lockedWithMultiplier; // Multiplied locked amount
}

struct MultiFeeInitializerParams {
    address emissionToken;
    address stakeToken;
    uint256 rewardStreamTime;
    uint256 rewardsLookback;
    LockType[] initLockTypes;
    uint256 defaultLockTypeIndex;
    address lockZap;
}

struct MultiFeeDistributionStorage {
    /// Addresses
    address emissionToken;
    address stakeToken;
    address lockZap;
    address bountyManager;
    address rewardCompounder;
    // OpEx
    address opsTreasury;
    uint256 operationExpenseRatio; // Reward ratio for operation expenses
    /// Config
    uint256 lockedSupply; // Total locked staked tokens in the contract
    uint256 lockedSupplyWithMultiplier; // Total locked value including multipliers
    LockType[] lockTypes; // lock types
    mapping(address => bool) emissionDistributors; // Addresses approved to call mint
    /// Rewards info
    uint256 rewardStreamTime; // Duration that rev rewards are streamed over
    uint256 rewardsLookback; // Duration that rewards loop back
    address[] rewardTokens; // Reward tokens being distributed
    mapping(address => bool) isRewardToken; // Stores whether a token is being destibuted to dLP lockers
    mapping(address => Reward) rewardData; // Reward data per token
    /// User info
    mapping(address => Balances) userBalances; // User balances
    mapping(address => StakedLock[]) userLocks; // User locks
    mapping(address => uint256) userSlippage; // User's defined max slippage used when performing compound trades
    mapping(address => uint256) defaultLockIndex; // Default lock index for relock
    mapping(address => uint256) lastClaimTime; // Last claim time of the user
    mapping(address => bool) autoRelockDisabled; // User's decision to be `relock` eligible
    mapping(address => bool) autocompoundDisabled; // User's decision to be `autocompound` eligible
    mapping(address => mapping(address => uint256)) userRewardPerTokenPaid; // user -> reward token -> rpt; RPT for paid amount
    mapping(address => mapping(address => uint256)) rewards; // user -> reward token -> amount; used to store reward amount
}
