// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {
    VolatileAMMPoolHelper, VolatileAMMPoolHelperInitParams
} from "../../../src/periphery/VolatileAMMPoolHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library VolatileAMMPoolHelperDeployer {
    using SafeERC20 for IERC20;

    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        VolatileAMMPoolHelperInitParams memory params
    ) internal returns (VolatileAMMPoolHelper) {
        string memory chainName = fs.getChainName(block.chainid);
        VolatileAMMPoolHelper instance = new VolatileAMMPoolHelper();
        IERC20(params.pairToken).forceApprove(address(instance), params.amountPaired);
        IERC20(params.weth9).forceApprove(address(instance), params.amountWeth9);
        instance.initialize(params);
        if (!forTesting) {
            console.log("VolatileAMMPoolHelper deployed:", address(instance));
            fs.saveAddress(contractLabel, chainName, address(instance));
            console.log("Saved VolatileAMMPoolHelper filesystem:", address(instance));
        }
        return instance;
    }
}
