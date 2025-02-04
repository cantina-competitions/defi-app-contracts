// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../script/foundry/deploy-libraries/_Index.s.sol";
import {console} from "forge-std/console.sol";
import {TestMerkleConstants} from "./merkle-sample/TestMerkleConstants.t.sol";
import {MockToken} from "./mocks/MockToken.t.sol";
import {MockWeth9} from "./mocks/MockWeth9.t.sol";
import {MockOracleRouter} from "./mocks/MockOracleRouter.t.sol";
import {
    MockAerodromeFixture,
    MockPool,
    MockPoolFactory,
    MockRouter,
    MockGauge
} from "./mocks/aerodrome/MockAerodromeFixture.t.sol";
import {DefiAppStaker} from "../src/DefiAppStaker.sol";
import {Balances} from "../src/dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {VolatileAMMPoolHelper, VolatileAMMPoolHelperInitParams} from "../src/periphery/VolatileAMMPoolHelper.sol";
import {DLockZap} from "../src/dependencies/DLockZap.sol";
import {
    DefiAppHomeCenter,
    EpochDistributor,
    EpochParams,
    EpochStates,
    MerkleUserDistroInput,
    StakingParams
} from "../src/DefiAppHomeCenter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingFixture is MockAerodromeFixture, TestMerkleConstants {
    // Test constants
    uint256 public constant INITIAL_WETH9_AMT = 1000 ether;
    uint256 public constant INITIAL_PAIR_AMT = 2_500_000 ether;
    uint256 public constant INIT_PRICE = (INITIAL_PAIR_AMT * 1e8) / INITIAL_WETH9_AMT; // INIT_PRICE = (emitToken / weth9); in 8 decimals
    uint256 public constant EIGHT_DECIMALS = 1e8;
    // Mocks
    MockToken public homeToken;
    MockWeth9 public weth9;
    MockPool public pool;
    MockPoolFactory public poolFactory;
    MockRouter public router;
    MockGauge public gauge;
    MockOracleRouter public oracleRouter;
    // Contracts
    VolatileAMMPoolHelper public vAmmPoolHelper;
    DefiAppStaker public staker;
    DefiAppHomeCenter public center;
    DLockZap public lockzap;

    function setUp() public virtual override {
        super.setUp();

        weth9 = new MockWeth9();
        homeToken = deploy_mock_tocken("Test Home", "tsHOME");
        vm.label(address(weth9), "Weth9");
        vm.label(address(homeToken), "HomeToken");

        (address poolFactory_, address router_) = deploy_mock_aerodrome(Admin.addr, address(weth9));
        poolFactory = MockPoolFactory(poolFactory_);
        router = MockRouter(payable(router_));

        // Deploy VolatileAMMPoolHelper
        VolatileAMMPoolHelperInitParams memory initParams = VolatileAMMPoolHelperInitParams({
            pairToken: address(homeToken),
            weth9: address(weth9),
            amountPaired: INITIAL_PAIR_AMT,
            amountWeth9: INITIAL_WETH9_AMT,
            routerAddr: address(router),
            poolFactory: address(poolFactory)
        });

        homeToken.mint(Admin.addr, INITIAL_PAIR_AMT);
        load_weth9(Admin.addr, INITIAL_PAIR_AMT, weth9);

        vm.startPrank(Admin.addr);
        vAmmPoolHelper = VolatileAMMPoolHelperDeployer.deploy(fs, "vAMMPoolHelper", TESTING_ONLY, initParams);
        vm.stopPrank();

        pool = MockPool(vAmmPoolHelper.pool());
        gauge = MockGauge(create_gauge(Admin.addr, address(homeToken), address(weth9), address(poolFactory)));

        staker = deploy_defiapp_staker(Admin.addr, address(homeToken), address(pool), address(gauge));
        oracleRouter = MockOracleRouter(staker.oracleRouter());
        oracleRouter.mock_set_price(address(weth9), WETH_USD_PRICE);
        center = deploy_defiapp_homecenter(Admin.addr, address(homeToken), staker, address(vAmmPoolHelper));

        lockzap =
            deploy_lockzap(Admin.addr, address(homeToken), address(weth9), address(staker), address(vAmmPoolHelper));
    }
}
