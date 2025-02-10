// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {console} from "forge-std/console.sol";
import {PublicSaleFixture} from "../PublicSaleFixture.t.sol";
import {MockUsdc} from "../mocks/MockUsdc.t.sol";
import {VestingManager, VestParams, Vest} from "../../src/token/VestingManager.sol";

contract TestUnitVestingManager is PublicSaleFixture {
    function setUp() public override {
        super.setUp();
        vestingAsset = deploy_mock_tocken("Vesting Asset", "tsVest");
        usdc = new MockUsdc();
        vestingManager = VestingManagerDeployer.deploy(
            fs,
            "VestingManager",
            TESTING_ONLY,
            VestingManagerInitParams({vestAsset: address(vestingAsset), name: "Vesting Manager", symbol: "VM"})
        );

        vm.warp(TEST_TIMESTAMP);
    }

    function test_createVesting() public {
        uint128 vestAmount = 1000 ether;
        vestingAsset.mint(Admin.addr, vestAmount);

        VestParams memory vestParams = VestParams({
            recipient: User1.addr,
            start: uint32(block.timestamp),
            cliffDuration: 0,
            stepDuration: TEST_STEP_DURATION,
            steps: TEST_STEPS,
            stepPercentage: FULL_PERCENTAGE / TEST_STEPS,
            amount: vestAmount,
            tokenURI: ""
        });

        vm.startPrank(Admin.addr);
        vestingAsset.approve(address(vestingManager), vestAmount);
        (, uint256 vestId,,) = vestingManager.createVesting(vestParams);
        vm.stopPrank();

        (uint256 remainingVested, uint256 canClaim) = vestingManager.vestSummary(vestId);

        assertEq(vestingManager.balanceOf(User1.addr), 1);
        assertEq(remainingVested, vestAmount);
        assertEq(canClaim, 0);
        assertEq(vestingAsset.balanceOf(User1.addr), 0);
        assertEq(vestingAsset.balanceOf(Admin.addr), 0);
        assertEq(vestingAsset.balanceOf(address(vestingManager)), vestAmount);
    }

    function test_createVestingWithPastStartDate() public {
        uint128 vestAmount = 1000 ether;
        uint256 backTimeSteps = 2;
        vestingAsset.mint(Admin.addr, vestAmount);

        VestParams memory vestParams = VestParams({
            recipient: User1.addr,
            start: uint32(block.timestamp - backTimeSteps * TEST_STEP_DURATION),
            cliffDuration: 0,
            stepDuration: TEST_STEP_DURATION,
            steps: TEST_STEPS,
            stepPercentage: FULL_PERCENTAGE / TEST_STEPS,
            amount: vestAmount,
            tokenURI: ""
        });

        vm.startPrank(Admin.addr);
        vestingAsset.approve(address(vestingManager), vestAmount);
        (, uint256 vestId,,) = vestingManager.createVesting(vestParams);
        vm.stopPrank();

        (uint256 remainingVested, uint256 canClaim) = vestingManager.vestSummary(vestId);

        assertEq(vestingManager.balanceOf(User1.addr), 1);
        assertEq(remainingVested, vestAmount);
        assertEq(canClaim, backTimeSteps * (vestAmount / TEST_STEPS));
        assertEq(vestingAsset.balanceOf(User1.addr), 0);
        assertEq(vestingAsset.balanceOf(Admin.addr), 0);
        assertEq(vestingAsset.balanceOf(address(vestingManager)), vestAmount);
    }

    function test_badAssetCreateVesting() public {
        uint128 vestAmount = 1000e6;
        // Mint USDC to Admin instead of vestingAsset
        usdc.mint(Admin.addr, vestAmount);

        VestParams memory vestParams = VestParams({
            recipient: User1.addr,
            start: uint32(block.timestamp),
            cliffDuration: 0,
            stepDuration: TEST_STEP_DURATION,
            steps: TEST_STEPS,
            stepPercentage: FULL_PERCENTAGE / TEST_STEPS,
            amount: vestAmount,
            tokenURI: ""
        });

        vm.startPrank(Admin.addr);
        usdc.approve(address(vestingManager), vestAmount);
        vm.expectRevert();
        vestingManager.createVesting(vestParams);
        vm.stopPrank();

        assertEq(vestingManager.balanceOf(User1.addr), 0);
    }

    function test_withdrawFromVest() public {
        uint128 vestAmount = 1000 ether;
        vestingAsset.mint(Admin.addr, vestAmount);

        VestParams memory vestParams = VestParams({
            recipient: User1.addr,
            start: uint32(block.timestamp),
            cliffDuration: 0,
            stepDuration: TEST_STEP_DURATION,
            steps: TEST_STEPS,
            stepPercentage: FULL_PERCENTAGE / TEST_STEPS,
            amount: vestAmount,
            tokenURI: ""
        });

        vm.startPrank(Admin.addr);
        vestingAsset.approve(address(vestingManager), vestAmount);
        (, uint256 vestId,,) = vestingManager.createVesting(vestParams);
        vm.stopPrank();

        assertEq(vestingAsset.balanceOf(User1.addr), 0);
        assertEq(vestingAsset.balanceOf(address(vestingManager)), vestAmount);

        Vest memory vest = vestingManager.getVestStruct(vestId);

        for (uint32 i = 0; i < TEST_STEPS; i++) {
            uint256 step = i + 1;
            vm.warp(TEST_TIMESTAMP + TEST_STEP_DURATION * step);

            (uint256 remainingVested, uint256 canClaim) = vestingManager.vestSummary(vestId);
            assertEq(remainingVested, vestAmount - vest.stepShares * (step - 1));
            assertEq(canClaim, vest.stepShares);

            vm.prank(User1.addr);
            vestingManager.withdraw(vestId);

            (remainingVested, canClaim) = vestingManager.vestSummary(vestId);
            assertEq(remainingVested, vestAmount - vest.stepShares * step);
            assertEq(canClaim, 0);

            assertEq(vestingAsset.balanceOf(User1.addr), vest.stepShares * step);
        }

        assertEq(vestingManager.vestBalance(vestId), 0);
        assertEq(vestingAsset.balanceOf(address(vestingManager)), 0);
    }

    function test_onlyRecipientCanWithdraw(address foe) public {
        vm.assume(foe != User1.addr && foe != address(0));

        uint128 vestAmount = 1000 ether;
        vestingAsset.mint(Admin.addr, vestAmount);

        VestParams memory vestParams = VestParams({
            recipient: User1.addr,
            start: uint32(block.timestamp),
            cliffDuration: 0,
            stepDuration: TEST_STEP_DURATION,
            steps: TEST_STEPS,
            stepPercentage: FULL_PERCENTAGE / TEST_STEPS,
            amount: vestAmount,
            tokenURI: ""
        });

        vm.startPrank(Admin.addr);
        vestingAsset.approve(address(vestingManager), vestAmount);
        (, uint256 vestId,,) = vestingManager.createVesting(vestParams);
        vm.stopPrank();

        vm.warp(TEST_TIMESTAMP + TEST_STEP_DURATION + 1 seconds);

        vm.startPrank(foe);
        vm.expectRevert();
        vestingManager.withdraw(vestId);

        assertEq(vestingAsset.balanceOf(User1.addr), 0);
        assertEq(vestingAsset.balanceOf(User2.addr), 0);
        assertEq(vestingAsset.balanceOf(address(vestingManager)), vestAmount);
    }

    function test_stopVesting() public {
        uint128 vestAmount = 1000 ether;
        vestingAsset.mint(Admin.addr, vestAmount);

        VestParams memory vestParams = VestParams({
            recipient: User1.addr,
            start: uint32(block.timestamp),
            cliffDuration: 0,
            stepDuration: TEST_STEP_DURATION,
            steps: TEST_STEPS,
            stepPercentage: FULL_PERCENTAGE / TEST_STEPS,
            amount: vestAmount,
            tokenURI: ""
        });

        vm.startPrank(Admin.addr);
        vestingAsset.approve(address(vestingManager), vestAmount);
        (, uint256 vestId,,) = vestingManager.createVesting(vestParams);
        vm.stopPrank();

        Vest memory vest = vestingManager.getVestStruct(vestId);

        vm.warp(TEST_TIMESTAMP + TEST_STEP_DURATION + 1 seconds);

        vm.prank(Admin.addr);
        vestingManager.stopVesting(vestId);

        assertEq(vestingAsset.balanceOf(User1.addr), vest.stepShares);
        assertEq(vestingAsset.balanceOf(address(vestingManager)), 0);
        assertEq(vestingAsset.balanceOf(Admin.addr), vestAmount - vest.stepShares);
    }
}
