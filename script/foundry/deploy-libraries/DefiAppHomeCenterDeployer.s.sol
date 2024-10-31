// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {DefiAppHomeCenter} from "../../../src/DefiAppHomeCenter.sol";
import {ERC1967ProxyDeployer} from "./ERC1967ProxyDeployer.s.sol";

struct DefiAppHomeCenterInitParams {
    address homeToken;
    address stakingAdress;
    uint128 initRps;
    uint32 initEpochDuration;
}

library DefiAppHomeCenterDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        bool onlyImplementation,
        DefiAppHomeCenterInitParams memory params
    ) internal returns (DefiAppHomeCenter) {
        string memory chainName = fs.getChainName(block.chainid);
        DefiAppHomeCenter instance = new DefiAppHomeCenter();
        if (onlyImplementation) {
            if (!forTesting) {
                console.log("DefiAppHomeCenter implementation deployed:", address(instance));
                fs.saveAddress(contractLabel, chainName, address(instance));
                console.log("Saved DefiAppHomeCenter filesystem:", address(instance));
            }
            return instance;
        } else {
            bytes memory initData = abi.encodeWithSelector(
                DefiAppHomeCenter.initialize.selector,
                params.homeToken,
                params.stakingAdress,
                params.initRps,
                params.initEpochDuration
            );
            return DefiAppHomeCenter(
                payable(ERC1967ProxyDeployer.deploy(fs, contractLabel, forTesting, address(instance), initData))
            );
        }
    }
}
