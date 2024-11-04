// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture} from "../BasicFixture.t.sol";
import {TestMerkleConstants} from "../merkle-sample/TestMerkleConstants.t.sol";
import {console} from "forge-std/console.sol";
import {MockToken} from "../mocks/MockToken.t.sol";
import {MockWeth9} from "../mocks/MockWeth9.t.sol";
import {MockOracleRouter} from "../mocks/MockOracleRouter.t.sol";
import {
    MockAerodromeFixture,
    MockPool,
    MockPoolFactory,
    MockRouter,
    MockGauge
} from "../mocks/aerodrome/MockAerodromeFixture.t.sol";
import {DefiAppStaker} from "../../src/DefiAppStaker.sol";
import {Balances} from "../../src/dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {VolatileAMMPoolHelper, VolatileAMMPoolHelperInitParams} from "../../src/periphery/VolatileAMMPoolHelper.sol";
import {DLockZap} from "../../src/dependencies/DLockZap.sol";
import {
    DefiAppHomeCenter,
    EpochDistributor,
    EpochParams,
    EpochStates,
    MerkleUserDistroInput,
    StakingParams
} from "../../src/DefiAppHomeCenter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestUserIntegratedFlows is MockAerodromeFixture, TestMerkleConstants {
    // Test constants
    uint256 public constant WETH_USD_PRICE = 2500 ether; // eth price in usd in 18 decimals
    uint256 public constant INITIAL_WETH9_AMT = 1000 ether;
    uint256 public constant INITIAL_PAIR_AMT = 2_500_000 ether;
    uint256 public constant INIT_PRICE = (INITIAL_PAIR_AMT * 1e8) / INITIAL_WETH9_AMT; // INIT_PRICE = (emitToken / weth9); in 8 decimals
    uint256 public constant EIGHT_DECIMALS = 1e8;
    // Mocks
    MockToken public homeToken;
    MockWeth9 public weth9;
    MockPool public pool;
    MockPoolFactory public poolFactory;
    MockRouter public router;
    MockGauge public gauge;
    MockOracleRouter public oracleRouter;
    // Contracts
    VolatileAMMPoolHelper public vAmmPoolHelper;
    DefiAppStaker public staker;
    DefiAppHomeCenter public center;
    DLockZap public lockzap;

    function setUp() public override {
        super.setUp();

        weth9 = new MockWeth9();
        homeToken = deploy_mock_tocken("Test Home", "tsHOME");
        vm.label(address(weth9), "Weth9");
        vm.label(address(homeToken), "HomeToken");

        (address poolFactory_, address router_) = deploy_mock_aerodrome(Admin.addr, address(weth9));
        poolFactory = MockPoolFactory(poolFactory_);
        router = MockRouter(payable(router_));

        // Deploy VolatileAMMPoolHelper
        VolatileAMMPoolHelperInitParams memory initParams = VolatileAMMPoolHelperInitParams({
            pairToken: address(homeToken),
            weth9: address(weth9),
            amountPaired: INITIAL_PAIR_AMT,
            amountWeth9: INITIAL_WETH9_AMT,
            routerAddr: address(router),
            poolFactory: address(poolFactory)
        });

        homeToken.mint(Admin.addr, INITIAL_PAIR_AMT);
        load_weth9(Admin.addr, INITIAL_PAIR_AMT, weth9);

        vm.startPrank(Admin.addr);
        vAmmPoolHelper = VolatileAMMPoolHelperDeployer.deploy(fs, "vAMMPoolHelper", TESTING_ONLY, initParams);
        vm.stopPrank();

        pool = MockPool(vAmmPoolHelper.pool());
        gauge = MockGauge(create_gauge(Admin.addr, address(homeToken), address(weth9), address(poolFactory)));

        staker = deploy_defiapp_staker(Admin.addr, address(homeToken), address(pool), address(gauge));
        center = deploy_defiapp_homecenter(Admin.addr, address(homeToken), staker, address(vAmmPoolHelper));

        oracleRouter = new MockOracleRouter();
        oracleRouter.mock_set_price(address(weth9), WETH_USD_PRICE);

        lockzap = deploy_lockzap(
            Admin.addr,
            address(homeToken),
            address(weth9),
            address(staker),
            address(vAmmPoolHelper),
            5000,
            address(oracleRouter)
        );
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
                false, // borrow
                address(0), // lendingPool
                address(weth9), // asset: to zap with
                amount, // assetAmt
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
                false, // borrow
                address(0), // lendingPool
                address(weth9), // asset: to zap with
                weth9Amt, // assetAmt
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
            console.log("minLpTokens", minLpTokens);
            lpAmount = lockzap.zap(
                false, // borrow
                address(0), // lendingPool
                address(weth9), // asset: to zap with
                amount, // assetAmt
                0, // emissionTokenAmt
                ONE_MONTH_TYPE_INDEX, // lockTypeIndex
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
            staking = StakingParams({weth9ToStake: wethToStake, minLpTokens: minLpTokens, typeIndex: 0});
        }

        // User1 claims and zaps
        load_weth9(User1.addr, staking.weth9ToStake, weth9);
        vm.startPrank(User1.addr);
        weth9.approve(address(center), staking.weth9ToStake);
        center.claim(1, user1DistroInput, user1DistroProof, staking);
        vm.stopPrank();
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
