// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {MockGauge} from "./MockGauge.t.sol";

contract MockGaugeFactory {
    function createGauge(
        address _forwarder,
        address _pool,
        address _feesVotingReward,
        address _rewardToken,
        bool isPool
    ) external returns (address gauge) {
        gauge = address(new MockGauge(_forwarder, _pool, _feesVotingReward, _rewardToken, msg.sender, isPool));
    }
}
