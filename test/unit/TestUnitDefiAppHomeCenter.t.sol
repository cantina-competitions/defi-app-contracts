// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {DefiAppStaker} from "../../src/DefiAppStaker.sol";
import {DefiAppHomeCenter, EpochStates} from "../../src/DefiAppHomeCenter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TestUnitDefiAppHomeCenter is BasicFixture {
    // Test constants
    uint128 public constant DEFAULT_RPS = 1 ether;
    uint32 public constant DEFAULT_EPOCH_DURATION = 30 days;

    MockToken public emissionToken;
    MockToken public stakeToken;

    DefiAppStaker public staker;
    DefiAppHomeCenter public center;

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

    function test_defiAppHomeCenterInitializeNextEpoch() public {
        uint256 knownBlock = 100;
        uint256 knownTimestamp = 1_728_975_600;

        vm.roll(knownBlock);
        vm.warp(knownTimestamp);

        vm.prank(Admin.addr);
        center.initializeNextEpoch();

        uint256 blockCadence = center.BLOCK_CADENCE();
        uint256 estimatedEndBlock = knownBlock + (DEFAULT_EPOCH_DURATION / blockCadence);
        uint128 estimatedDistributed = DEFAULT_RPS * DEFAULT_EPOCH_DURATION;

        assertEq(1, center.getCurrentEpoch());
        assertEq(estimatedEndBlock, center.getEpochParams(1).endBlock);
        assertEq(estimatedDistributed, center.getEpochParams(1).toBeDistributed);
        assertEq(knownTimestamp, center.getEpochParams(1).startTimestamp);
        assertEq(uint8(EpochStates.Ongoing), center.getEpochParams(1).state);
    }
}
