// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {VestingManager} from "../../../src/token/VestingManager.sol";

struct VestingManagerInitParams {
    address vestAsset;
    string name;
    string symbol;
}

library VestingManagerDeployer {
    function deploy(FileSystem fs, string memory contractLabel, bool forTesting, VestingManagerInitParams memory params)
        internal
        returns (VestingManager)
    {
        string memory chainName = fs.getChainName(block.chainid);
        VestingManager instance = new VestingManager(params.vestAsset, params.name, params.symbol);
        if (!forTesting) {
            console.log("VestingManager deployed:", address(instance));
            fs.saveAddress(contractLabel, chainName, address(instance));
            console.log("Saved VestingManager to filesystem:", address(instance));
        }
        return instance;
    }
}
