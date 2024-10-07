// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {console} from "forge-std/console.sol";
import {BaseFixture, MockToken} from "../BaseFixture.t.sol";
import {
    MultiFeeDistribution,
    MultiFeeInitializerParams,
    Balances,
    LockType,
    StakedLock
} from "../../src/reference/MultiFeeDistribution/MultiFeeDistribution.sol";

contract TestUnitMultiFeeDistribution is BaseFixture {
    uint256 public constant ONE_UNIT = 1 ether;

    uint256 public constant ONE_MONTH_TYPE_INDEX = 0;
    uint256 public constant THREE_MONTH_TYPE_INDEX = 1;
    uint256 public constant SIX_MONTH_TYPE_INDEX = 2;
    uint256 public constant TWELVE_MONTH_TYPE_INDEX = 3;

    uint128 public constant ONE_MONTH_MULTIPLIER = 1;
    uint128 public constant THREE_MONTH_MULTIPLIER = 3;
    uint128 public constant SIX_MONTH_MULTIPLIER = 6;
    uint128 public constant TWELVE_MONTH_MULTIPLIER = 12;

    MockToken public emissionToken;
    MockToken public stakeToken;
    MultiFeeDistribution public mfd;

    function setUp() public override {
        super.setUp();
        emissionToken = deploy_mock_tocken("Test Home", "tsHOME");
        stakeToken = deploy_mock_tocken("Test LP Home", "tsLP");

        LockType[] memory initLockTypes = new LockType[](4);
        initLockTypes[ONE_MONTH_TYPE_INDEX] = LockType({duration: 30 days, multiplier: ONE_MONTH_MULTIPLIER});
        initLockTypes[THREE_MONTH_TYPE_INDEX] = LockType({duration: 90 days, multiplier: THREE_MONTH_MULTIPLIER});
        initLockTypes[SIX_MONTH_TYPE_INDEX] = LockType({duration: 180 days, multiplier: SIX_MONTH_MULTIPLIER});
        initLockTypes[TWELVE_MONTH_TYPE_INDEX] = LockType({duration: 360 days, multiplier: TWELVE_MONTH_MULTIPLIER});

        MultiFeeInitializerParams memory params = MultiFeeInitializerParams({
            emissionToken: address(emissionToken),
            stakeToken: address(stakeToken),
            rewardStreamTime: 7 days,
            rewardsLookback: 1 days,
            initLockTypes: initLockTypes,
            defaultLockTypeIndex: ONE_MONTH_TYPE_INDEX,
            lockZap: address(1)
        });

        mfd = MultiFeeDistributionDeployer.deploy(fs, "MultiFeeDistribution", TESTING_ONLY, false, params);
    }

    function test_userCanStakeAndStateUpdatesProperly(uint128 _amount) public {
        // uint256 _amount = 100 * ONE_UNIT;
        stakeToken.mint(User1.addr, _amount);

        vm.startPrank(User1.addr);
        stakeToken.approve(address(mfd), _amount);
        mfd.stake(_amount, User1.addr, ONE_MONTH_TYPE_INDEX);
        vm.stopPrank();

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
}
