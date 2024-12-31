// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {PublicSale} from "../../../src/token/PublicSale.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct PublicSaleInitParams {
    address admin;
    address treasury;
    address usdc;
}

library PublicSaleDeployer {
    function deploy(FileSystem fs, string memory contractLabel, bool forTesting, PublicSaleInitParams memory params)
        internal
        returns (PublicSale)
    {
        string memory chainName = fs.getChainName(block.chainid);
        PublicSale instance = new PublicSale(params.admin, params.treasury, IERC20(params.usdc));
        if (!forTesting) {
            console.log("PublicSale deployed:", address(instance));
            fs.saveAddress(contractLabel, chainName, address(instance));
            console.log("Saved PublicSale to filesystem:", address(instance));
        }
        return instance;
    }
}
