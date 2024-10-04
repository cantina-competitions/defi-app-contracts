// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {FsConstants} from "./FsConstants.s.sol";
import {console} from "forge-std/console.sol";

contract FileSystem is FsConstants, Script {
    error FileNotFound(string chainName, string contractLabel);

    bytes temp;

    function saveAddress(string memory contractLabel, string memory chainName, address addr) public {
        string memory path = getContractLabelPathAt(contractLabel, chainName);
        createAndSaveFile(path, vm.toString(addr));
    }

    function getAddress(string memory contractLabel, string memory chainName) public returns (address addr) {
        string memory content = vm.readFile(getContractLabelPathAt(contractLabel, chainName));
        temp = bytes(content);
        uint256 contentLength = temp.length;
        if (contentLength > 42) {
            uint256 pops = contentLength - 42;
            for (uint256 i = 0; i < pops; i++) {
                temp.pop();
            }
        }
        string memory modContent = string(temp);
        addr = vm.parseAddress(modContent);
        delete temp;
    }

    function getContractLabelPathAt(string memory contractLabel, string memory chainName)
        public
        pure
        returns (string memory path)
    {
        path = string.concat("deployments/", chainName, "/", contractLabel);
    }

    function createAndSaveFile(string memory path, string memory content) public {
        try vm.removeFile(path) {}
        catch {
            console.log(string(abi.encodePacked("Creating a new record at ", path)));
        }
        vm.writeLine(path, content);
    }

    function getByteCodeFromFs(string memory path) public view returns (bytes memory) {
        bytes memory code = vm.parseBytes(vm.readFile(path));
        return code;
    }
}
