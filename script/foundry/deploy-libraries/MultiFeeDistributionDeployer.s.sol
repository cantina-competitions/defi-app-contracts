// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {
    MultiFeeDistribution,
    MultiFeeInitializerParams
} from "../../../src/reference/MultiFeeDistribution/MultiFeeDistribution.sol";
import {ERC1967ProxyDeployer} from "./ERC1967ProxyDeployer.s.sol";

library MultiFeeDistributionDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool onlyImplementation,
        MultiFeeInitializerParams memory params
    ) internal returns (MultiFeeDistribution) {
        string memory chainName = fs.getChainName(block.chainid);

        console.log("Deploying MultiFeeDistribution...");
        MultiFeeDistribution instance = new MultiFeeDistribution();
        console.log("MultiFeeDistribution implementation:", address(instance));

        if (onlyImplementation) {
            fs.saveAddress(contractLabel, chainName, address(instance));
            console.log("Saved MultiFeeDistribution filesystem:", address(instance));
            return instance;
        } else {
            bytes memory initData = abi.encodeWithSelector(MultiFeeDistribution.initialize.selector, params);
            return MultiFeeDistribution(ERC1967ProxyDeployer.deploy(fs, contractLabel, address(instance), initData));
        }
    }
}
