// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {DefiAppStaker, MFDBase, MFDBaseInitializerParams} from "../../../src/DefiAppStaker.sol";
import {ERC1967ProxyDeployer} from "./ERC1967ProxyDeployer.s.sol";

library DefiAppStakerDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        bool onlyImplementation,
        MFDBaseInitializerParams memory params
    ) internal returns (DefiAppStaker) {
        string memory chainName = fs.getChainName(block.chainid);
        DefiAppStaker instance = new DefiAppStaker();
        if (onlyImplementation) {
            if (!forTesting) {
                console.log("DefiAppStaker implementation deployed:", address(instance));
                fs.saveAddress(contractLabel, chainName, address(instance));
                console.log("Saved DefiAppStaker filesystem:", address(instance));
            }
            return instance;
        } else {
            bytes memory initData = abi.encodeWithSelector(MFDBase.initialize.selector, params);
            return
                DefiAppStaker(ERC1967ProxyDeployer.deploy(fs, contractLabel, forTesting, address(instance), initData));
        }
    }
}
