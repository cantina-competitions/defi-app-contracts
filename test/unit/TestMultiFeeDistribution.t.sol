// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BaseFixture, MockToken} from "../BaseFixture.t.sol";
import {
    MultiFeeDistribution,
    MultiFeeInitializerParams
} from "../../src/reference/MultiFeeDistribution/MultiFeeDistribution.sol";

contract TestUnitMultiFeeDistribution is BaseFixture {
    MockToken public token;
    MultiFeeDistribution public mfd;

    function setUp() public override {
        super.setUp();
        token = deploy_mock_tocken("TestHome", "tsHOME");

        //     emissionToken;
        // address lockZap;
        // uint256 rewardDuration;
        // uint256 rewardsLookback;
        // uint256 lockDuration;
        // uint256 burnRatio;
        // address treasury;
        // uint256 vestDuration;
    }
}
