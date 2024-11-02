// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {console} from "forge-std/console.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {
    MFDBase,
    MFDBaseInitializerParams,
    Balances,
    LockType,
    StakedLock
} from "../../src/dependencies/MultiFeeDistribution/MFDBase.sol";

contract TestUnitMFDBase is BasicFixture {
    uint256 public constant ONE_UNIT = 1 ether;

    MockToken public emissionToken;
    MockToken public stakeToken;
    MFDBase public mfd;

    function setUp() public override {
        super.setUp();
        emissionToken = deploy_mock_tocken("Test Home", "tsHOME");
        stakeToken = deploy_mock_tocken("Test LP Home", "tsLP");

        LockType[] memory initLockTypes = new LockType[](4);
        initLockTypes[ONE_MONTH_TYPE_INDEX] = LockType({duration: 30 days, multiplier: ONE_MONTH_MULTIPLIER});
        initLockTypes[THREE_MONTH_TYPE_INDEX] = LockType({duration: 90 days, multiplier: THREE_MONTH_MULTIPLIER});
        initLockTypes[SIX_MONTH_TYPE_INDEX] = LockType({duration: 180 days, multiplier: SIX_MONTH_MULTIPLIER});
        initLockTypes[TWELVE_MONTH_TYPE_INDEX] = LockType({duration: 360 days, multiplier: TWELVE_MONTH_MULTIPLIER});

        MFDBaseInitializerParams memory params = MFDBaseInitializerParams({
            emissionToken: address(emissionToken),
            stakeToken: address(stakeToken),
            rewardStreamTime: 7 days,
            rewardsLookback: 1 days,
            initLockTypes: initLockTypes,
            defaultLockTypeIndex: ONE_MONTH_TYPE_INDEX
        });

        vm.startPrank(Admin.addr);
        mfd = MFDBaseDeployer.deploy(fs, "MFDBase", TESTING_ONLY, false, params);
        vm.stopPrank();
    }

    function test_userCanStakeAndStateUpdatesProperly(uint128 _amount) public {
        stake_in_mfd(User1.addr, _amount, ONE_MONTH_TYPE_INDEX);

        // Check proper value transfer of stakeToken
        assertEq(stakeToken.balanceOf(address(mfd)), _amount);
        assertEq(stakeToken.balanceOf(User1.addr), 0);

        // Check proper storage of staked amount and with multiplier
        assertEq(mfd.getLockedSupply(), _amount);
        assertEq(mfd.getLockedSupplyWithMultiplier(), _amount * ONE_MONTH_MULTIPLIER);

        // Check proper storage of staked amount and with multiplier
        if (_amount > 0) {
            // Check the `userLocks` mapping
            StakedLock[] memory locks = mfd.getUserLocks(User1.addr);
            console.log("user locks length: %d", locks.length);
            assertEq(locks.length, 1);
            assertEq(locks[0].amount, _amount);
            assertEq(locks[0].unlockTime, block.timestamp + 30 days);
            assertEq(locks[0].multiplier, ONE_MONTH_MULTIPLIER);
            assertEq(locks[0].duration, 30 days);

            // Check the `userBalances` mapping
            Balances memory balances = mfd.getUserBalances(User1.addr);
            assertEq(balances.total, _amount);
            assertEq(balances.locked, _amount);
            assertEq(balances.unlocked, 0);
            assertEq(balances.lockedWithMultiplier, _amount * ONE_MONTH_MULTIPLIER);
        }
    }

    function test_rewardDistributionWorks() public {
        uint256 user1Amount = 80 * ONE_UNIT;
        uint256 user2Amount = 20 * ONE_UNIT;
        stake_in_mfd(User1.addr, user1Amount, ONE_MONTH_TYPE_INDEX);
        stake_in_mfd(User2.addr, user2Amount, ONE_MONTH_TYPE_INDEX);

        // Set a timestamp
        uint256 timestamp = 1_728_370_800;
        vm.warp(timestamp);

        // Distribute rewards
        uint256 rewardAmount = 700 * ONE_UNIT;
        distribute_rewards_to_mfd(emissionToken, rewardAmount);

        // Check proper storage of reward data
        assertEq(mfd.getRewardData(address(emissionToken)).balance, rewardAmount);
        assertEq(mfd.getRewardData(address(emissionToken)).periodFinish, timestamp + 7 days);
        assertEq(mfd.getRewardData(address(emissionToken)).lastUpdateTime, timestamp);
        uint256 rewardPerSecond = (rewardAmount * ONE_UNIT) / 7 days;
        assertEq(mfd.getRewardData(address(emissionToken)).rewardPerSecond, rewardPerSecond);
        assertEq(mfd.getRewardData(address(emissionToken)).rewardPerTokenStored, 0);

        // Rewards distributed in 1 day
        uint256 expectedRewardsDistributed = rewardPerSecond * 1 days / ONE_UNIT; // rps is scaled by 1e18
        vm.warp(timestamp + 1 days);
        vm.roll(1);

        // Check proper claimable amounts for each user
        assertEq(
            mfd.getUserClaimableRewards(User1.addr)[0].amount,
            (expectedRewardsDistributed * user1Amount) / (user1Amount + user2Amount)
        );
        assertEq(
            mfd.getUserClaimableRewards(User2.addr)[0].amount,
            (expectedRewardsDistributed * user2Amount) / (user1Amount + user2Amount)
        );
    }

    function test_userCanWithdrawExpiredLocks() public {
        // Set a timestamp
        uint256 timestamp = 1_728_370_800;
        vm.warp(timestamp);

        uint256 amount = 100 * ONE_UNIT;
        stake_in_mfd(User1.addr, amount, ONE_MONTH_TYPE_INDEX);

        // Check that user cannot withdraw before lock expires
        vm.expectRevert();
        vm.prank(User1.addr);
        mfd.withdrawExpiredLocks();
        assertEq(stakeToken.balanceOf(User1.addr), 0);

        // Check that user can withdraw after lock expires
        vm.warp(timestamp + 31 days);
        vm.roll(1);
        vm.prank(User1.addr);
        mfd.withdrawExpiredLocks();
        assertEq(stakeToken.balanceOf(User1.addr), amount);

        // Check state updates properly
        assertEq(mfd.getUserBalances(User1.addr).total, 0);
        assertEq(mfd.getUserBalances(User1.addr).locked, 0);
        assertEq(mfd.getUserBalances(User1.addr).unlocked, 0);
        assertEq(mfd.getUserBalances(User1.addr).lockedWithMultiplier, 0);
        assertEq(mfd.getLockedSupply(), 0);
        assertEq(mfd.getLockedSupplyWithMultiplier(), 0);
    }

    function stake_in_mfd(address user, uint256 amount, uint256 lockTypeIndex) internal {
        stakeToken.mint(user, amount);
        vm.startPrank(user);
        stakeToken.approve(address(mfd), amount);
        mfd.stake(amount, user, lockTypeIndex);
        vm.stopPrank();
    }

    function distribute_rewards_to_mfd(MockToken token, uint256 amount) internal {
        token.mint(Admin.addr, amount);
        vm.startPrank(Admin.addr);
        token.approve(address(mfd), amount);
        mfd.distributeAndTrackReward(address(emissionToken), amount);
        vm.stopPrank();
    }

    function distribute_unseen_rewards_to_mfd(MockToken token, uint256 amount) internal {
        token.mint(Admin.addr, amount);
        vm.prank(Admin.addr);
        token.transfer(address(mfd), amount);
    }
}
