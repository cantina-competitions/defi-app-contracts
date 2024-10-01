// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAggregator} from "./IAggregator.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

interface IChainlinkAggregator is IAggregator, IAggregatorV3 {}
