// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {console} from "forge-std/console.sol";
import {VolatileAMMPoolHelper} from "../../src/periphery/VolatileAMMPoolHelper.sol";
import {MockToken, ERC20} from "../mocks/MockToken.t.sol";
import {
    MockAerodromeFixture,
    MockPool,
    MockPoolFactory,
    MockRouter,
    MockVoter
} from "../mocks/aerodrome/MockAerodromeFixture.t.sol";

contract TestUnitVolatileAMMPoolHelper is MockAerodromeFixture {
    VolatileAMMPoolHelper public vAmmPoolHelper;

    address public weth9;
    MockPoolFactory public poolFactory;
    MockRouter public router;

    function setUp() public override {
        super.setUp();
        weth9 = address(new MockToken("Mock Weth9", "WETH9"));
        (address poolFactory_, address router_) = deploy_mock_aerodrome(Admin.addr, address(weth9));
        poolFactory = MockPoolFactory(poolFactory_);
        router = MockRouter(payable(router_));
        // Additional setup if needed
    }

    function test_mockAerodromeSetUp() public {
        _testMockAerodromeIsFunctional(poolFactory, router);
    }
}
