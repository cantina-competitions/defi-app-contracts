// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

library ERC1967ProxyDeployer {
    function deploy(
        FileSystem fs,
        string memory contractLabel,
        bool forTesting,
        address implementation,
        bytes memory initData
    ) internal returns (address) {
        string memory chainName = fs.getChainName(block.chainid);
        bytes memory contructorArgs = abi.encode(implementation, initData);
        address proxy = address(new ERC1967Proxy(implementation, initData));

        if (!forTesting) {
            console.log("ERC1967Proxy constructor arguments:");
            console.logBytes(contructorArgs);
            console.log("ERC1967Proxy deployed:", proxy);
            fs.saveAddress(contractLabel, chainName, proxy);
        }
        return proxy;
    }
}
