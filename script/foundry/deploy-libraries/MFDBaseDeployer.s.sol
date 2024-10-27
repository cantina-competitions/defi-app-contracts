// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {MFDBase, MFDBaseInitializerParams} from "../../../src/dependencies/MultiFeeDistribution/MFDBase.sol";
import {ERC1967ProxyDeployer} from "./ERC1967ProxyDeployer.s.sol";

library MFDBaseDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        bool onlyImplementation,
        MFDBaseInitializerParams memory params
    ) internal returns (MFDBase) {
        string memory chainName = fs.getChainName(block.chainid);
        MFDBase instance = new MFDBase();
        if (onlyImplementation) {
            if (!forTesting) {
                console.log("MFDBase implementation deployed:", address(instance));
                fs.saveAddress(contractLabel, chainName, address(instance));
                console.log("Saved MFDBase filesystem:", address(instance));
            }
            return instance;
        } else {
            bytes memory initData = abi.encodeWithSelector(MFDBase.initialize.selector, params);
            return MFDBase(ERC1967ProxyDeployer.deploy(fs, contractLabel, forTesting, address(instance), initData));
        }
    }
}
