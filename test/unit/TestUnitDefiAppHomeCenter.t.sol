// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BaseFixture, MockToken} from "../BaseFixture.t.sol";
import {DefiAppStaker} from "../../src/DefiAppStaker.sol";
import {DefiAppHomeCenter} from "../../src/DefiAppHomeCenter.sol";

contract TestUnitDefiAppHomeCenter is BaseFixture {
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

        DefiAppHomeCenterInitParams memory params = DefiAppHomeCenterInitParams({
            homeToken: address(emissionToken),
            stakingAdress: address(staker),
            initRps: DEFAULT_RPS,
            initEpochDuration: DEFAULT_EPOCH_DURATION
        });

        center = DefiAppHomeCenterDeployer.deploy(fs, "DefiAppHomeCenter", TESTING_ONLY, false, params);

        vm.prank(Admin.addr);
        staker.setHomeCenter(center);
    }

    function test_defiAppHomeCenterDeploymentState() public view {
        assertEq(address(emissionToken), center.homeToken());
        assertEq(address(staker), center.stakingAddress());
        assertEq(DEFAULT_RPS, center.getDefaultRps());
        assertEq(DEFAULT_EPOCH_DURATION, center.getDefaultEpochDuration());
        assertEq(0, center.getCurrentEpoch());
    }
}
