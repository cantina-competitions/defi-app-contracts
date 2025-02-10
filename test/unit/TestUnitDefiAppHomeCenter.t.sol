// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {TestMerkleConstants} from "../merkle-sample/TestMerkleConstants.t.sol";
import {console} from "forge-std/console.sol";
import {DefiAppStaker} from "../../src/DefiAppStaker.sol";
import {
    DefiAppHomeCenter,
    EpochDistributor,
    EpochParams,
    EpochStates,
    MerkleUserDistroInput,
    StakingParams
} from "../../src/DefiAppHomeCenter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TestUnitDefiAppHomeCenter is BasicFixture, TestMerkleConstants {
    // Test constants
    uint256 public constant KNOWN_BLOCK = 100;
    uint256 public constant KNOWN_TIMESTAMP = 1_728_975_600;

    MockToken public emissionToken;
    MockToken public stakeToken;

    DefiAppStaker public staker;
    DefiAppHomeCenter public center;

    function setUp() public override {
        super.setUp();

        emissionToken = deploy_mock_tocken("Test Home", "tsHOME");
        stakeToken = deploy_mock_tocken("Test LP Home", "tsLP");

        staker = deploy_defiapp_staker(Admin.addr, address(emissionToken), address(stakeToken), address(0));
        center = deploy_defiapp_homecenter(Admin.addr, address(emissionToken), staker, address(0));

        vm.roll(KNOWN_BLOCK);
        vm.warp(KNOWN_TIMESTAMP);
    }

    function test_defiAppHomeCenterDeploymentState() public view {
        assertEq(address(emissionToken), center.homeToken());
        assertEq(address(staker), center.stakingAddress());
        assertEq(DEFAULT_RPS, center.getDefaultRps());
        assertEq(DEFAULT_EPOCH_DURATION, center.getDefaultEpochDuration());
        assertEq(0, center.getCurrentEpoch());
        assertEq(address(center), address(staker.getHomeCenter()));
        assertEq(false, center.isVotingLive());
        assertEq(false, center.isMintingActive());
    }

    function test_defiAppHomerCenterPermissionedSetters(address someone) public {
        vm.assume(someone != address(0));
        bool isSomeoneTheAdmin = someone == Admin.addr;
        bytes32 defaultAdmin = 0x00;
        if (isSomeoneTheAdmin) {
            vm.startPrank(someone);
            center.setDefaultRps(DEFAULT_RPS * 2);
            center.setDefaultEpochDuration(DEFAULT_EPOCH_DURATION * 2);
            center.setVoting(true);
            center.setMintingActive(true);
            vm.stopPrank();

            // Confirm state changes
            assertEq(DEFAULT_RPS * 2, center.getDefaultRps());
            assertEq(DEFAULT_EPOCH_DURATION * 2, center.getDefaultEpochDuration());
            assertEq(true, center.isVotingLive());
            assertEq(true, center.isMintingActive());
        } else {
            vm.startPrank(someone);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, someone, defaultAdmin)
            );
            center.setDefaultRps(DEFAULT_RPS * 2);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, someone, defaultAdmin)
            );
            center.setDefaultEpochDuration(DEFAULT_EPOCH_DURATION * 2);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, someone, defaultAdmin)
            );
            center.setVoting(true);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, someone, defaultAdmin)
            );
            center.setMintingActive(true);
            vm.stopPrank();
        }

        if (someone == address(stakeToken)) {
            vm.prank(someone);
            center.callHookRegisterStaker(User1.addr);

            // Confirm state changes
            assertEq(User1.addr, center.getUserConfig(User1.addr).receiver);
        } else {
            vm.expectRevert(DefiAppHomeCenter.DefiAppHomeCenter_notStaker.selector);
            vm.prank(someone);
            center.callHookRegisterStaker(User1.addr);
            // Confirm NO state changes
            assertEq(address(0), center.getUserConfig(User1.addr).receiver);
        }
    }

    function test_initializeNextEpoch() public {
        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        uint256 blockCadence = center.BLOCK_CADENCE();
        uint256 estimatedEndBlock = KNOWN_BLOCK + (DEFAULT_EPOCH_DURATION / blockCadence);
        uint128 estimatedDistributed = DEFAULT_RPS * DEFAULT_EPOCH_DURATION;

        assertEq(1, center.getCurrentEpoch());
        assertEq(estimatedEndBlock, center.getEpochParams(1).endBlock);
        assertEq(estimatedDistributed, center.getEpochParams(1).toBeDistributed);
        assertEq(KNOWN_TIMESTAMP, center.getEpochParams(1).startTimestamp);
        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(1).state);
    }

    function test_settleEpochGood() public {
        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        vm.roll(center.getEpochParams(1).endBlock + 1);
        vm.warp(KNOWN_TIMESTAMP + DEFAULT_EPOCH_DURATION + center.BLOCK_CADENCE());
        assertEq(uint8(EpochStates.Finalized), center.getEpochParams(1).state);

        uint256 tokensToDistribute = center.getEpochParams(1).toBeDistributed;
        emissionToken.mint(Admin.addr, tokensToDistribute);

        vm.startPrank(Admin.addr);
        emissionToken.approve(address(center), tokensToDistribute);
        center.settleEpoch(1, balanceRoot, distributionRoot, balanceMagicProof, distributionMagicProof);
        vm.stopPrank();
        assertEq(uint8(EpochStates.Distributed), center.getEpochParams(1).state);
    }

    function test_cannotSettleEpochNotFinalized() public {
        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        uint256 tokensToDistribute = center.getEpochParams(1).toBeDistributed;
        emissionToken.mint(Admin.addr, tokensToDistribute);

        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(1).state);

        vm.startPrank(Admin.addr);
        emissionToken.approve(address(center), tokensToDistribute);
        vm.expectRevert(DefiAppHomeCenter.DefiAppHomeCenter_invalidEpochState.selector);
        center.settleEpoch(1, balanceRoot, distributionRoot, balanceMagicProof, distributionMagicProof);
        vm.stopPrank();
    }

    function test_cannotSettleWithFakeProofs(bytes32[4] memory badProofs) public {
        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        vm.roll(center.getEpochParams(1).endBlock + 1);
        vm.warp(KNOWN_TIMESTAMP + DEFAULT_EPOCH_DURATION + center.BLOCK_CADENCE());

        uint256 tokensToDistribute = center.getEpochParams(1).toBeDistributed;
        emissionToken.mint(Admin.addr, tokensToDistribute);

        bytes32[] memory badBalanceProof = new bytes32[](2);
        badBalanceProof[0] = badProofs[0];
        badBalanceProof[1] = badProofs[1];

        bytes32[] memory badDistributionProof = new bytes32[](2);
        badDistributionProof[0] = badProofs[2];
        badDistributionProof[1] = badProofs[3];

        vm.startPrank(Admin.addr);
        emissionToken.approve(address(center), tokensToDistribute);
        vm.expectRevert(EpochDistributor.EpochDistributor_invalidBalanceProof.selector);
        center.settleEpoch(1, balanceRoot, distributionRoot, badBalanceProof, badDistributionProof);
        vm.stopPrank();
    }

    function test_canInitializeNextEpochDuringAppropriateTiming() public {
        bool isInitialized;
        vm.prank(Admin.addr);
        isInitialized = center.initializeNextEpoch();
        assertEq(true, isInitialized);
        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(1).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(2).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(3).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(4).state);

        // Can initiate Epoch 2, 1 block before Epoch 1 ends
        EpochParams memory params1 = center.getEpochParams(1);
        vm.roll(params1.endBlock - 1); // one block before
        vm.warp(KNOWN_TIMESTAMP + DEFAULT_EPOCH_DURATION - center.BLOCK_CADENCE());
        isInitialized = center.initializeNextEpoch();
        assertEq(true, isInitialized);
        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(1).state);
        assertEq(uint8(EpochStates.Initialized), center.getEpochParams(2).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(3).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(4).state);

        // Can initiate Epoch 3, 1 block after Epoch 2 ends
        EpochParams memory params2 = center.getEpochParams(2);
        vm.roll(params2.endBlock + 1); // one block after
        vm.warp(KNOWN_TIMESTAMP + 2 * DEFAULT_EPOCH_DURATION + center.BLOCK_CADENCE());
        isInitialized = center.initializeNextEpoch();
        assertEq(true, isInitialized);
        assertEq(uint8(EpochStates.Finalized), center.getEpochParams(1).state);
        assertEq(uint8(EpochStates.Finalized), center.getEpochParams(2).state);
        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(3).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(4).state);

        // CANNOT initialize next epoch before before preface
        EpochParams memory params3 = center.getEpochParams(3);
        uint256 prefaceBlocks = center.NEXT_EPOCH_BLOCKS_PREFACE();
        vm.roll(params3.endBlock - (prefaceBlocks + 1));
        vm.warp(KNOWN_TIMESTAMP + 3 * DEFAULT_EPOCH_DURATION - prefaceBlocks * center.BLOCK_CADENCE());
        isInitialized = center.initializeNextEpoch();
        assertEq(false, isInitialized); // NOTE: should return false
        assertEq(uint8(EpochStates.Finalized), center.getEpochParams(1).state);
        assertEq(uint8(EpochStates.Finalized), center.getEpochParams(2).state);
        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(3).state);
        assertEq(uint8(EpochStates.Undefined), center.getEpochParams(4).state);
    }

    function test_claimTokensSingleEpoch() public {
        vm.startPrank(address(staker));
        center.callHookRegisterStaker(User1.addr);
        center.callHookRegisterStaker(User2.addr);
        vm.stopPrank();

        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        vm.roll(center.getEpochParams(1).endBlock + 1);
        vm.warp(KNOWN_TIMESTAMP + DEFAULT_EPOCH_DURATION + center.BLOCK_CADENCE());

        uint256 tokensToDistribute = center.getEpochParams(1).toBeDistributed;
        emissionToken.mint(Admin.addr, tokensToDistribute);
        vm.startPrank(Admin.addr);
        emissionToken.approve(address(center), tokensToDistribute);
        center.settleEpoch(1, balanceRoot, distributionRoot, balanceMagicProof, distributionMagicProof);
        vm.stopPrank();

        StakingParams memory noStaking = StakingParams({weth9ToStake: 0, minLpTokens: 0, typeIndex: 0});

        // User1 claims tokens
        uint256 tokensToReceive = user1DistroInput.tokens; // from {TestMerkleConstants.t.sol}
        vm.prank(User1.addr);
        center.claim(1, user1DistroInput, user1DistroProof, noStaking);
        assertEq(emissionToken.balanceOf(User1.addr), tokensToReceive);

        // User2 claims tokens
        uint256 tokensToReceive2 = user2DistroInput.tokens; // from {TestMerkleConstants.t.sol}
        vm.prank(User2.addr);
        center.claim(1, user2DistroInput, user2DistroProof, noStaking);
        assertEq(emissionToken.balanceOf(User2.addr), tokensToReceive2);
    }
}
