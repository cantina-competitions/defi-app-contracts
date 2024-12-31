// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {console} from "forge-std/console.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {MockUsdc} from "../mocks/MockUsdc.t.sol";
import {VestingManager, VestParams, Vest} from "../../src/token/VestingManager.sol";
import {PublicSale} from "../../src/token/PublicSale.sol";

contract TestUnitPublicSale is BasicFixture {
    MockToken public saleAsset;
    MockUsdc public usdc;

    VestingManager public vestingManager;
    PublicSale public publicSale;

    uint128 public constant FULL_PERCENTAGE = 1e18;
    uint32 public constant TEST_TIMESTAMP = 1735718400;
    // uint32 public constant TEST_STEP_DURATION = 10 minutes;
    // uint32 public constant TEST_STEPS = 20;

    uint256 public constant MIN_DEPOSIT_AMOUNT = 250 * 1e6;
    uint256 public constant MAX_DEPOSIT_AMOUNT = 100_000 * 1e6;
    uint256 public constant SALE_START = TEST_TIMESTAMP + 7 days;
    uint256 public constant SALE_END = TEST_TIMESTAMP + 14 days;

    uint256 public constant TIER_1 = 0;
    uint256 public constant TIER_2 = 1;
    uint256 public constant TIER_3 = 2;

    function setUp() public override {
        super.setUp();
        saleAsset = deploy_mock_tocken("Sale Token", "sTKN");
        usdc = new MockUsdc();

        publicSale = PublicSaleDeployer.deploy(
            fs,
            "PublicSale",
            TESTING_ONLY,
            PublicSaleInitParams({admin: Admin.addr, treasury: Admin.addr, usdc: address(usdc)})
        );

        vestingManager = VestingManagerDeployer.deploy(
            fs,
            "VestingManager",
            TESTING_ONLY,
            VestingManagerInitParams({vestAsset: address(saleAsset), name: "Vesting Manager", symbol: "VM"})
        );
    }

    function test_publicSaleStageAtDeploy() public view {
        PublicSale.Stages stage = publicSale.getCurrentStage();
        // enum Stages {
        //     Completed, // Sale is final, 0
        //     ComingSoon, // Contract is deployed but not yet started, 1
        //     TokenPurchase, // Deposit and purchase tokens, 2
        //     ClaimAndVest // Claim and start vesting, 3
        // }
        assertEq(uint8(stage), uint8(PublicSale.Stages.ComingSoon));
    }

    function test_settingPublicSale(address someone) public {
        if (someone == Admin.addr) {
            vm.startPrank(someone);
            publicSale.setSaleSchedule(SALE_START, SALE_END);
            publicSale.setSaleParameters(MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
            vm.stopPrank();

            (uint256 start, uint256 end) = publicSale.saleSchedule();
            (uint256 min, uint256 max) = publicSale.saleParameters();

            assertEq(start, SALE_START);
            assertEq(end, SALE_END);
            assertEq(min, MIN_DEPOSIT_AMOUNT);
            assertEq(max, MAX_DEPOSIT_AMOUNT);
        } else {
            vm.startPrank(someone);
            vm.expectRevert();
            publicSale.setSaleSchedule(SALE_START, SALE_END);
            vm.expectRevert();
            publicSale.setSaleParameters(MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
            vm.stopPrank();

            (uint256 start, uint256 end) = publicSale.saleSchedule();
            (uint256 min, uint256 max) = publicSale.saleParameters();

            assertEq(start, 0);
            assertEq(end, 0);
            assertEq(min, 0);
            assertEq(max, 0);
        }
    }

    function test_purchaseTokens(uint40 purchaseAmount) public {
        vm.startPrank(Admin.addr);
        publicSale.setSaleSchedule(SALE_START, SALE_END);
        publicSale.setSaleParameters(MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
        publicSale.unpause();
        vm.stopPrank();

        usdc.mint(User1.addr, purchaseAmount);

        vm.prank(User1.addr);
        usdc.approve(address(publicSale), purchaseAmount);

        // Trying to purchase tokens before the sale starts
        vm.prank(User1.addr);
        vm.expectPartialRevert(PublicSale.WrongStage.selector);
        publicSale.depositUSDC(purchaseAmount, TIER_1);

        assertEq(publicSale.getRemainingDepositAmount(User1.addr), MAX_DEPOSIT_AMOUNT);

        vm.warp(SALE_START + 1);

        if (purchaseAmount < MIN_DEPOSIT_AMOUNT || purchaseAmount > MAX_DEPOSIT_AMOUNT) {
            // Trying to purchase with less or max amount
            vm.prank(User1.addr);
            vm.expectPartialRevert(PublicSale.InvalidPurchaseInputHandler.selector);
            publicSale.depositUSDC(purchaseAmount, TIER_1);
        } else {
            // Successful purchase of tokens
            vm.prank(User1.addr);
            publicSale.depositUSDC(purchaseAmount, TIER_1);

            uint256 totalAmountDeposited = publicSale.totalFundsCollected();
            PublicSale.UserDepositInfo memory depositInfo = publicSale.getUserDepositInfo(User1.addr);

            assertEq(publicSale.getRemainingDepositAmount(User1.addr), MAX_DEPOSIT_AMOUNT - purchaseAmount);
            assertEq(depositInfo.amountDeposited, uint256(purchaseAmount));
            assertEq(totalAmountDeposited, uint256(purchaseAmount));
            assertEq(usdc.balanceOf(Admin.addr), uint256(purchaseAmount));
        }
    }

    function test_purchaseTokensAfterSale() public {
        vm.startPrank(Admin.addr);
        publicSale.setSaleSchedule(SALE_START, SALE_END);
        publicSale.setSaleParameters(MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
        publicSale.unpause();
        vm.stopPrank();

        usdc.mint(User1.addr, MAX_DEPOSIT_AMOUNT);
        usdc.approve(address(publicSale), MAX_DEPOSIT_AMOUNT);

        vm.warp(SALE_END + 1);

        vm.prank(User1.addr);
        vm.expectPartialRevert(PublicSale.WrongStage.selector);
        publicSale.depositUSDC(MAX_DEPOSIT_AMOUNT, TIER_1);

        uint256 totalAmountDeposited = publicSale.totalFundsCollected();
        PublicSale.UserDepositInfo memory depositInfo = publicSale.getUserDepositInfo(User1.addr);

        assertEq(publicSale.getRemainingDepositAmount(User1.addr), MAX_DEPOSIT_AMOUNT);
        assertEq(depositInfo.amountDeposited, 0);
        assertEq(totalAmountDeposited, 0);
        assertEq(usdc.balanceOf(Admin.addr), 0);
    }

    function test_userBuysFromAllTiers() public {
        uint256 priceTier1 = 0.1 ether;
        uint256 priceTier2 = 0.2 ether;
        uint256 priceTier3 = 0.4 ether;

        vm.startPrank(Admin.addr);
        publicSale.setSaleSchedule(SALE_START, SALE_END);
        publicSale.setSaleParameters(MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
        publicSale.setTiers(
            [
                PublicSale.Tier(priceTier1, 1_000_000e6, 720 days), // 0
                PublicSale.Tier(priceTier2, 2_000_000e6, 360 days), // 1
                PublicSale.Tier(priceTier3, 4_000_000e6, 0 days) // 2
            ]
        );
        publicSale.unpause();
        vm.stopPrank();

        usdc.mint(User1.addr, MIN_DEPOSIT_AMOUNT * 3);

        vm.warp(SALE_START + 1);

        vm.startPrank(User1.addr);
        usdc.approve(address(publicSale), MAX_DEPOSIT_AMOUNT * 3);
        // Purchase from Tier 1
        publicSale.depositUSDC(MIN_DEPOSIT_AMOUNT, TIER_1);
        // Purchase from Tier 2
        publicSale.depositUSDC(MIN_DEPOSIT_AMOUNT, TIER_2);
        // Purchase from Tier 3
        publicSale.depositUSDC(MIN_DEPOSIT_AMOUNT, TIER_3);
        vm.stopPrank();

        uint256 totalAmountDeposited = publicSale.totalFundsCollected();
        PublicSale.UserDepositInfo memory depositInfo = publicSale.getUserDepositInfo(User1.addr);

        assertEq(publicSale.getRemainingDepositAmount(User1.addr), MAX_DEPOSIT_AMOUNT - MIN_DEPOSIT_AMOUNT * 3);
        assertEq(depositInfo.amountDeposited, MIN_DEPOSIT_AMOUNT * 3);
        assertEq(totalAmountDeposited, MIN_DEPOSIT_AMOUNT * 3);
        assertEq(usdc.balanceOf(Admin.addr), MIN_DEPOSIT_AMOUNT * 3);
        assertEq(depositInfo.purchases[TIER_1].purchasedTokens, compute_token_amount(MIN_DEPOSIT_AMOUNT, priceTier1));
        assertEq(depositInfo.purchases[TIER_2].purchasedTokens, compute_token_amount(MIN_DEPOSIT_AMOUNT, priceTier2));
        assertEq(depositInfo.purchases[TIER_3].purchasedTokens, compute_token_amount(MIN_DEPOSIT_AMOUNT, priceTier3));
    }

    function test_claimAndStartVesting() public {
        uint256 priceTier1 = 0.1 ether;
        uint256 priceTier2 = 0.2 ether;
        uint256 priceTier3 = 0.4 ether;

        vm.startPrank(Admin.addr);
        publicSale.setSaleSchedule(SALE_START, SALE_END);
        publicSale.setSaleParameters(MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
        publicSale.setTiers(
            [
                PublicSale.Tier(priceTier1, 1_000_000e6, 720 days), // 0
                PublicSale.Tier(priceTier2, 2_000_000e6, 360 days), // 1
                PublicSale.Tier(priceTier3, 4_000_000e6, 0 days) // 2
            ]
        );
        publicSale.unpause();
        vm.stopPrank();

        usdc.mint(User1.addr, MIN_DEPOSIT_AMOUNT * 3);

        vm.warp(SALE_START + 1);

        vm.startPrank(User1.addr);
        usdc.approve(address(publicSale), MAX_DEPOSIT_AMOUNT * 3);
        // Purchase from Tier 1
        publicSale.depositUSDC(MIN_DEPOSIT_AMOUNT, TIER_1);
        // Purchase from Tier 2
        publicSale.depositUSDC(MIN_DEPOSIT_AMOUNT, TIER_2);
        // Purchase from Tier 3
        publicSale.depositUSDC(MIN_DEPOSIT_AMOUNT, TIER_3);
        vm.stopPrank();

        vm.warp(SALE_END + 1);
        assertEq(uint8(publicSale.getCurrentStage()), uint8(PublicSale.Stages.Completed));

        vm.prank(User1.addr);
        vm.expectPartialRevert(PublicSale.WrongStage.selector);
        publicSale.claimAndStartVesting();

        vm.prank(Admin.addr);
        publicSale.setVestingReady(saleAsset, address(vestingManager), uint32(SALE_END + 2));

        assertEq(uint8(publicSale.getCurrentStage()), uint8(PublicSale.Stages.ClaimAndVest));

        uint256 soldTokens = publicSale.totalTokensPurchased();
        saleAsset.mint(address(Admin.addr), soldTokens);

        vm.prank(Admin.addr);
        saleAsset.approve(address(publicSale), soldTokens);

        assertEq(saleAsset.balanceOf(address(vestingManager)), 0);

        vm.prank(User1.addr);
        publicSale.claimAndStartVesting();

        assertEq(saleAsset.balanceOf(address(vestingManager)), soldTokens);
    }

    function compute_token_amount(uint256 usdcAmount, uint256 priceE18) internal pure returns (uint256) {
        uint256 tokenAmount = usdcAmount * 1e18 / priceE18;
        console.log("Token amount: ", tokenAmount);
        return tokenAmount;
    }
}
