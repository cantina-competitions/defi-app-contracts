// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../script/foundry/deploy-libraries/_Index.s.sol";
import {VmSafe} from "forge-std/StdUtils.sol";
import {MockToken} from "./mocks/MockToken.t.sol";

contract BaseFixture is Test {
    ///////// Storage /////////
    VmSafe.Wallet public User1;
    VmSafe.Wallet public User2;
    VmSafe.Wallet public User3;
    VmSafe.Wallet public User4;
    VmSafe.Wallet public Admin;
    VmSafe.Wallet public Treasury;

    function setUp() public virtual {
        User1 = vm.createWallet("User1");
        User2 = vm.createWallet("User2");
        User3 = vm.createWallet("User3");
        User4 = vm.createWallet("User4");
        Admin = vm.createWallet("Admin");
        Treasury = vm.createWallet("Treasury");
    }

    function deploy_mock_tocken(string memory _name, string memory _symbol) internal returns (MockToken) {
        return new MockToken(_name, _symbol);
    }
}
