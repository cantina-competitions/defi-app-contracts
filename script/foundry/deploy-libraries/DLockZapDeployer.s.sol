// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {DLockZap} from "../../../src/dependencies/DLockZap.sol";
import {ERC1967ProxyDeployer} from "./ERC1967ProxyDeployer.s.sol";

struct DLockZapInitializerParams {
    address emissionToken;
    address weth9;
    address mfd;
    address poolHelper;
    uint256 lpRatio;
    address oracleRouter;
}

library DLockZapDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        bool onlyImplementation,
        DLockZapInitializerParams memory params
    ) internal returns (DLockZap) {
        string memory chainName = fs.getChainName(block.chainid);
        DLockZap instance = new DLockZap();
        if (onlyImplementation) {
            if (!forTesting) {
                console.log("DLockZap implementation deployed:", address(instance));
                fs.saveAddress(contractLabel, chainName, address(instance));
                console.log("Saved DLockZap filesystem:", address(instance));
            }
            return instance;
        } else {
            bytes memory initData = abi.encodeWithSelector(
                DLockZap.initialize.selector,
                params.emissionToken,
                params.weth9,
                params.mfd,
                params.poolHelper,
                params.lpRatio,
                params.oracleRouter
            );
            return DLockZap(
                payable(ERC1967ProxyDeployer.deploy(fs, contractLabel, forTesting, address(instance), initData))
            );
        }
    }
}
