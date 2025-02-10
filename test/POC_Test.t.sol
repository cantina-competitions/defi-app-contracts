// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {StakingFixture} from "./StakingFixture.t.sol";
import {PublicSaleFixture} from "./PublicSaleFixture.t.sol";
import {Balances} from "../src/dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {EpochParams, EpochStates, MerkleUserDistroInput, StakingParams} from "../src/DefiAppHomeCenter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract POC_test is StakingFixture, PublicSaleFixture {
    function setUp() public override(StakingFixture, PublicSaleFixture) {
        StakingFixture.setUp();
        PublicSaleFixture.setUp();

        /// The following should be available:

        /// Users (see BasicFixture.t.sol)
        /// - User1
        /// - User2
        /// - User3
        /// - User4
        /// - Admin
        /// - Treasury

        /// Contracts:
        /// - staker (DefiAppStaker.sol)
        /// - center (DefiAppHomeCenter.sol)
        /// - lockzap (DLockZap.sol)
        /// - vAmmPoolHelper (VolatileAMMPoolHelper.sol)
        /// - publicSale (PublicSale.sol)
        /// - vestingManager (VestingManager.sol)

        /// Mocks:
        /// - weth9 (MockWeth9.t.sol)
        /// - usdc (MockUsdc.t.sol)
        /// - homeToken (MockToken.t.sol)
        /// - poolFactory (MockPoolFactory.t.sol) mock aerodrome setup
        /// - router (MockRouter.t.sol) to swap on mock aerodrome
        /// - pool (MockPool.t.sol) setup for weth9 and homeToken
        /// - gauge (MockGauge.t.sol) setup for weth9 and homeToken
        /// - oracleRouter (MockOracleRouter.t.sol) to provide mockPrice of weth9
    }

    function test_poc_example() public {
        // Test code here

        // Example User flow: they "zap" into staking
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
}
