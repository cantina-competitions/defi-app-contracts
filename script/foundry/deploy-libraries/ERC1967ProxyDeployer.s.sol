// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {FileSystem} from "../utils/FileSystem.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

library ERC1967ProxyDeployer {
    function deploy(FileSystem fs, string memory contractLabel, address implementation, bytes memory initData)
        internal
        returns (address)
    {
        string memory chainName = fs.getChainName(block.chainid);

        address proxy;
        bytes memory contructorArgs = abi.encode(implementation, initData);
        console.log("ERC1967Proxy constructor arguments:");
        console.logBytes(contructorArgs);

        proxy = address(new ERC1967Proxy(implementation, initData));

        console.log("ERC1967Proxy deployed:", proxy);
        fs.saveAddress(contractLabel, chainName, proxy);
        return proxy;
    }
}
