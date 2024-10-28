// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {console} from "forge-std/console.sol";
import {DefiAppStaker} from "../../src/DefiAppStaker.sol";
import {DefiAppHomeCenter, EpochDistributor, EpochParams, EpochStates} from "../../src/DefiAppHomeCenter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TestUnitDefiAppHomeCenter is BasicFixture {
    // Test constants
    uint128 public constant DEFAULT_RPS = 1 ether;
    uint32 public constant DEFAULT_EPOCH_DURATION = 30 days;
    uint256 public constant KNOWN_BLOCK = 100;
    uint256 public constant KNOWN_TIMESTAMP = 1_728_975_600;

    MockToken public emissionToken;
    MockToken public stakeToken;

    DefiAppStaker public staker;
    DefiAppHomeCenter public center;

    /// Merkle roots and proofs for testing
    /// @notice The roots below are obtained from tests and data used in `test/merkle-sample/merklefunctions.test.ts`
    /// To get this values set `const DEBUG = true;` in below and run with:
    ///  `bun test test/merkle-sample/merklefunctions.test.ts`
    bytes32 public constant BALANCE_INFO_ROOT = 0xcc1138a7a86c3d9bfd34f64b8e57c7de8ed1911392831f8dcd60438c90b491a7;
    bytes32[] public balanceMagicProof;
    bytes32 public constant DISTRIBUTION_ROOT = 0x6b7d6aec8859e8597879a0de649625d86699539c6b66030cca2f8343797a86da;
    bytes32[] public distributionMagicProof;

    function setUp() public override {
        super.setUp();

        emissionToken = deploy_mock_tocken("Test Home", "tsHOME");
        stakeToken = deploy_mock_tocken("Test LP Home", "tsLP");

        address placeHolderLockZap = address(1);
        staker = deploy_defiapp_staker(Admin.addr, address(emissionToken), address(stakeToken), placeHolderLockZap);

        vm.startPrank(Admin.addr);
        DefiAppHomeCenterInitParams memory params = DefiAppHomeCenterInitParams({
            homeToken: address(emissionToken),
            stakingAdress: address(staker),
            initRps: DEFAULT_RPS,
            initEpochDuration: DEFAULT_EPOCH_DURATION
        });
        center = DefiAppHomeCenterDeployer.deploy(fs, "DefiAppHomeCenter", TESTING_ONLY, false, params);
        staker.setHomeCenter(center);
        vm.stopPrank();

        vm.roll(KNOWN_BLOCK);
        vm.warp(KNOWN_TIMESTAMP);

        /// Refer to comment above about `Merkle roots and proofs for testing`
        balanceMagicProof = new bytes32[](2);
        balanceMagicProof[0] = 0x68eff8bdb05c9df1554ae8bc031b7e51904f0e39512d69802abf31f9b8f40f08;
        balanceMagicProof[1] = 0xaf7d40f3762de0f03633aa1a43787eb9d6ed84e94456e546aded7eb641349c0c;
        distributionMagicProof = new bytes32[](2);
        distributionMagicProof[0] = 0x3e55fc3ca9bf379cfc1eb9830c00c51a3687c002c77b9aa9eacf5a2555903dee;
        distributionMagicProof[1] = 0x2abb7a8aa2c91f02addae2b8d89585ae94e34f442a4526d526e1a70a3888d74f;
    }

    function test_defiAppHomeCenterDeploymentState() public view {
        assertEq(address(emissionToken), center.homeToken());
        assertEq(address(staker), center.stakingAddress());
        assertEq(DEFAULT_RPS, center.getDefaultRps());
        assertEq(DEFAULT_EPOCH_DURATION, center.getDefaultEpochDuration());
        assertEq(0, center.getCurrentEpoch());
        assertEq(address(center), address(staker.getHomeCenter()));
        assertEq(false, center.isVotingLive());
        assertEq(false, center.isMiningActive());
    }

    function test_defiAppHomerCenterPermissionedSetters(address someone) public {
        vm.assume(someone != address(0));
        bool isSomeoneTheAdmin = someone == Admin.addr;
        bytes32 defaultAdmin = 0x00;
        bytes32 stakeAddressRole = keccak256("STAKE_ADDRESS_ROLE");
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
            assertEq(true, center.isMiningActive());
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
            center.registerStaker(User1.addr);

            // Confirm state changes
            assertEq(User1.addr, center.getUserConfig(User1.addr).receiver);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, someone, stakeAddressRole
                )
            );
            vm.prank(someone);
            center.registerStaker(User1.addr);
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
        center.settleEpoch(1, BALANCE_INFO_ROOT, DISTRIBUTION_ROOT, balanceMagicProof, distributionMagicProof);
        vm.stopPrank();
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
        center.settleEpoch(1, BALANCE_INFO_ROOT, DISTRIBUTION_ROOT, balanceMagicProof, distributionMagicProof);
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
        center.settleEpoch(1, BALANCE_INFO_ROOT, DISTRIBUTION_ROOT, badBalanceProof, badDistributionProof);
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
}
