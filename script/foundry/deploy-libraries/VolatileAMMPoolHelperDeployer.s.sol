// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {
    VolatileAMMPoolHelper, VolatileAMMPoolHelperInitParams
} from "../../../src/periphery/VolatileAMMPoolHelper.sol";

library VolatileAMMPoolHelperDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        VolatileAMMPoolHelperInitParams memory params
    ) internal returns (VolatileAMMPoolHelper) {
        string memory chainName = fs.getChainName(block.chainid);
        VolatileAMMPoolHelper instance = new VolatileAMMPoolHelper(params);
        if (!forTesting) {
            console.log("VolatileAMMPoolHelper deployed:", address(instance));
            fs.saveAddress(contractLabel, chainName, address(instance));
            console.log("Saved VolatileAMMPoolHelper filesystem:", address(instance));
        }
        return instance;
    }
}
