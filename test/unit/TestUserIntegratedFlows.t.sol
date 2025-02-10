// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {StakingFixture} from "../StakingFixture.t.sol";
import {Balances} from "../../src/dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {StakingParams} from "../../src/DefiAppHomeCenter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestUserIntegratedFlows is StakingFixture {
    function setUp() public override {
        super.setUp();
    }

    function test_userFlowZapIntoStakingOnlyWeth9() public {
        // User flow: Zap into staking
        uint256 amount = 1 ether;
        load_weth9(User1.addr, amount, weth9);

        uint256 lpAmount;
        vm.startPrank(User1.addr);
        {
            weth9.approve(address(lockzap), amount);
            (,, uint256 minLpTokens) = vAmmPoolHelper.quoteAddLiquidity(0, amount);
            console.log("minLpTokens", minLpTokens);
            lpAmount = lockzap.zap(
                amount, // weth9Amt
                0, // emissionTokenAmt
                ONE_MONTH_TYPE_INDEX, // lockTypeIndex
                minLpTokens // slippage check
            );
        }
        vm.stopPrank();
        assertEq(lpAmount, IERC20(address(gauge)).balanceOf(address(staker)));
        Balances memory userBalances = staker.getUserBalances(User1.addr);
        assertEq(lpAmount, userBalances.total);
        assertEq(lpAmount, userBalances.locked);
        assertEq(0, userBalances.unlocked);
        assertEq(lpAmount * ONE_MONTH_MULTIPLIER, userBalances.lockedWithMultiplier);
    }

    function test_userFlowZapIntoStakingWithHomeAndWeth9() public {
        // User flow: Zap into staking
        uint256 weth9Amt = 1 ether;
        uint256 homeAmt = (weth9Amt * INIT_PRICE) / EIGHT_DECIMALS;
        load_weth9(User1.addr, weth9Amt, weth9);
        homeToken.mint(User1.addr, homeAmt);

        uint256 lpAmount;
        vm.startPrank(User1.addr);
        {
            weth9.approve(address(lockzap), weth9Amt);
            homeToken.approve(address(lockzap), homeAmt);
            (,, uint256 minLpTokens) = vAmmPoolHelper.quoteAddLiquidity(homeAmt, weth9Amt);
            lpAmount = lockzap.zap(
                weth9Amt, // weth9Amt
                homeAmt, // emissionTokenAmt
                ONE_MONTH_TYPE_INDEX, // lockTypeIndex
                minLpTokens // slippage check
            );
        }
        vm.stopPrank();
        assertEq(lpAmount, IERC20(address(gauge)).balanceOf(address(staker)));
        Balances memory userBalances = staker.getUserBalances(User1.addr);
        assertEq(lpAmount, userBalances.total);
        assertEq(lpAmount, userBalances.locked);
        assertEq(0, userBalances.unlocked);
        assertEq(lpAmount * ONE_MONTH_MULTIPLIER, userBalances.lockedWithMultiplier);
    }

    function test_userFlowClaimAndZap() public {
        // User flow: Zap into staking
        uint256 amount = 1 ether;
        load_weth9(User1.addr, amount, weth9);

        uint256 lpAmount;
        vm.startPrank(User1.addr);
        {
            weth9.approve(address(lockzap), amount);
            (,, uint256 minLpTokens) = vAmmPoolHelper.quoteAddLiquidity(0, amount);
            lpAmount = lockzap.zap(
                amount, // weth9Amt
                0, // emissionTokenAmt
                THREE_MONTH_TYPE_INDEX, // lockTypeIndex
                minLpTokens // slippage check
            );
        }
        vm.stopPrank();

        settle_test_epoch();

        // Build staking params
        StakingParams memory staking;
        {
            uint256 claimableHomeTokens = user1DistroInput.tokens; // from {TestMerkleConstants.t.sol}
            (, uint256 wethToStake, uint256 minLpTokens) = vAmmPoolHelper.quoteAddLiquidity(claimableHomeTokens, 0);
            staking =
                StakingParams({weth9ToStake: wethToStake, minLpTokens: minLpTokens, typeIndex: THREE_MONTH_TYPE_INDEX});
            lpAmount += minLpTokens;
        }

        uint256 centerPrevBal = homeToken.balanceOf(address(center));

        // User1 claims and zaps
        load_weth9(User1.addr, staking.weth9ToStake, weth9);
        vm.startPrank(User1.addr);
        weth9.approve(address(center), staking.weth9ToStake);
        center.claim(1, user1DistroInput, user1DistroProof, staking);
        vm.stopPrank();

        // Check proper balance change at `center` contract
        assertEq(homeToken.balanceOf(address(center)), (centerPrevBal - user1DistroInput.tokens));
        assertEq(weth9.balanceOf(address(center)), 0);

        // Check proper staking balance updates at `staker` contract
        Balances memory userBalances = staker.getUserBalances(User1.addr);
        assertEq(userBalances.total >= lpAmount, true);
        assertEq(userBalances.locked >= lpAmount, true);
        assertEq(userBalances.unlocked == 0, true);
        assertEq(userBalances.lockedWithMultiplier, lpAmount * THREE_MONTH_MULTIPLIER);
    }

    function settle_test_epoch() internal {
        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        vm.roll(center.getEpochParams(1).endBlock + 1);
        vm.warp(DEFAULT_EPOCH_DURATION + center.BLOCK_CADENCE());

        uint256 tokensToDistribute = center.getEpochParams(1).toBeDistributed;
        homeToken.mint(Admin.addr, tokensToDistribute);
        vm.startPrank(Admin.addr);
        homeToken.approve(address(center), tokensToDistribute);
        center.settleEpoch(1, balanceRoot, distributionRoot, balanceMagicProof, distributionMagicProof);
        vm.stopPrank();
    }
}
