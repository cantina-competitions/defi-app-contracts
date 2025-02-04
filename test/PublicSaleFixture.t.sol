// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture} from "./BasicFixture.t.sol";
import {MockToken} from "./mocks/MockToken.t.sol";
import {MockUsdc} from "./mocks/MockUsdc.t.sol";
import {VestingManager, VestParams, Vest} from "../src/token/VestingManager.sol";
import {PublicSale} from "../src/token/PublicSale.sol";

contract PublicSaleFixture is BasicFixture {
    VestingManager public vestingManager;
    PublicSale public publicSale;
    MockToken public vestingAsset;
    MockUsdc public usdc;

    uint128 public constant FULL_PERCENTAGE = 1e18;
    uint32 public constant TEST_TIMESTAMP = 1735718400;
    // uint32 public constant TEST_STEP_DURATION = 10 minutes;
    // uint32 public constant TEST_STEPS = 20;

    uint256 public constant MIN_DEPOSIT_AMOUNT = 250 * 1e6;
    uint256 public constant MAX_DEPOSIT_AMOUNT = 100_000 * 1e6;
    uint256 public constant SALE_START = TEST_TIMESTAMP + 7 days;
    uint256 public constant SALE_END = TEST_TIMESTAMP + 14 days;

    uint256 public constant TIER_1 = 0;
    uint256 public constant TIER_2 = 1;
    uint256 public constant TIER_3 = 2;

    uint32 public constant TEST_STEP_DURATION = 10 minutes;
    uint32 public constant TEST_STEPS = 20;

    function setUp() public virtual override {
        super.setUp();
        vestingAsset = deploy_mock_tocken("Test Sale Asset", "tsSALE");
        usdc = new MockUsdc();

        publicSale = PublicSaleDeployer.deploy(
            fs,
            "PublicSale",
            TESTING_ONLY,
            PublicSaleInitParams({admin: Admin.addr, treasury: Admin.addr, usdc: address(usdc)})
        );

        vestingManager = VestingManagerDeployer.deploy(
            fs,
            "VestingManager",
            TESTING_ONLY,
            VestingManagerInitParams({vestAsset: address(vestingAsset), name: "Vesting Manager", symbol: "VM"})
        );
    }
}
