// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BasicFixture} from "../../BasicFixture.t.sol";
import {MockPool} from "./MockPool.t.sol";
import {MockPoolFactory} from "./MockPoolFactory.t.sol";
import {MockVoter} from "./MockVoter.t.sol";
import {MockGauge} from "./MockGauge.t.sol";
import {MockGaugeFactory} from "./MockGaugeFactory.t.sol";
import {MockFactoryRegistry} from "./MockFactoryRegistry.t.sol";
import {MockRouter} from "./MockRouter.t.sol";
import {IRouter} from "../../../src/interfaces/aerodrome/IRouter.sol";
import {MockVe, MockToken} from "./MockVe.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAerodromeFixture is BasicFixture {
    address internal constant MOCK_FORWARDER = address(256); // fakeForwarder
    address internal constant MOCK_VOTING_REWARDS_FACTORY = address(512); // fakeVotingRewardsFactory
    address internal constant MOCK_MANAGE_REWARDS_FACTORY = address(768); // fakeManagedRewardsFactory

    function deploy_mock_aerodrome(address admin, address mockWeth9)
        internal
        returns (address poolFactory, address router)
    {
        vm.startPrank(admin);
        MockPool pool = new MockPool();
        MockPoolFactory poolFactory_ = new MockPoolFactory(address(pool));
        MockGaugeFactory gaugeFactory_ = new MockGaugeFactory();
        MockFactoryRegistry factoryRegistry_ = new MockFactoryRegistry(
            address(poolFactory_),
            MOCK_VOTING_REWARDS_FACTORY, // votingRewardsFactory
            address(gaugeFactory_), // gaugeFactory
            MOCK_MANAGE_REWARDS_FACTORY // managedRewardsFactory
        );
        MockVe ve_ = new MockVe("MockTokenVe", "ve");
        MockVoter voter_ = new MockVoter(MOCK_FORWARDER, address(ve_), address(factoryRegistry_));
        poolFactory_.setVoter(address(voter_));
        MockRouter router_ =
            new MockRouter(MOCK_FORWARDER, address(factoryRegistry_), address(poolFactory_), address(voter_), mockWeth9);
        vm.stopPrank();

        return (address(poolFactory_), address(router_));
    }

    function create_gauge(address admin, address tokenA, address tokenB, address poolFactory)
        internal
        returns (address gauge)
    {
        vm.startPrank(admin);
        address voter = MockPoolFactory(poolFactory).voter();
        MockVoter(voter).whitelistToken(address(tokenA), true);
        MockVoter(voter).whitelistToken(address(tokenB), true);
        address pool = MockPoolFactory(poolFactory).getPool(tokenA, tokenB, false);
        gauge = MockVoter(voter).createGauge(poolFactory, pool);
        vm.stopPrank();
    }

    function _testMockAerodromeIsFunctional(MockPoolFactory poolFactory, MockRouter router) internal {
        assertEq(address(poolFactory) != address(0), true);
        assertEq(address(router) != address(0), true);

        MockToken mockTokenA = new MockToken("MockA", "MKA");
        MockToken mockTokenB = new MockToken("MockB", "MKB");

        vm.label(address(mockTokenA), "MockTokenA");
        vm.label(address(mockTokenB), "MockTokenB");

        uint256 amountA = 100_000 ether; // assume price tokenB/tokenA = 2
        uint256 amountB = 200_000 ether;
        mockTokenA.mint(User1.addr, amountA);
        mockTokenB.mint(User1.addr, amountB);

        //  router.addLiquidity(...)
        vm.startPrank(User1.addr);
        mockTokenA.approve(address(router), type(uint256).max);
        mockTokenB.approve(address(router), type(uint256).max);
        router.addLiquidity(
            address(mockTokenA),
            address(mockTokenB),
            false,
            amountA,
            amountB,
            amountA,
            amountB,
            User1.addr,
            block.timestamp + 1
        );
        vm.stopPrank();

        // IPoolFactory(factory).getPool(A,B,boolean)
        address pool = poolFactory.getPool(address(mockTokenA), address(mockTokenB), false);
        assertEq(pool != address(0), true);

        // IPoolFactory(factory).getFee(pool, false)
        {
            uint256 fee = poolFactory.getFee(pool, false);
            assertEq(fee != 0, true);
        }

        // Create a gauge
        address gauge = create_gauge(Admin.addr, address(mockTokenA), address(mockTokenB), address(poolFactory));
        assertEq(gauge != address(0), true);

        // router.zapIn(...)
        uint256 smallAmtA = 1 ether; // an amount that has negligible slippage for testing only
        uint256 halfSmallAmtA = smallAmtA / 2;
        IRouter.Route[] memory routeA = new IRouter.Route[](1);
        routeA[0] = IRouter.Route(address(mockTokenB), address(mockTokenA), false, address(poolFactory));
        IRouter.Route[] memory routeB = new IRouter.Route[](1);
        routeB[0] = IRouter.Route(address(mockTokenA), address(mockTokenB), false, address(poolFactory));

        uint256 quoteB = router.getAmountsOut(halfSmallAmtA, routeB)[0];

        IRouter.Zap memory zapInPool =
            IRouter.Zap(address(mockTokenA), address(mockTokenB), false, address(poolFactory), 0, 0, 0, 0);
        (zapInPool.amountOutMinA, zapInPool.amountOutMinB, zapInPool.amountAMin, zapInPool.amountBMin) = router
            .generateZapInParams(
            zapInPool.tokenA,
            zapInPool.tokenB,
            zapInPool.stable,
            zapInPool.factory,
            halfSmallAmtA,
            quoteB,
            routeA,
            routeB
        );

        mockTokenA.mint(User2.addr, amountA);
        vm.startPrank(User2.addr);
        mockTokenA.approve(address(router), type(uint256).max);
        uint256 lpTokens =
            router.zapIn(address(mockTokenA), halfSmallAmtA, halfSmallAmtA, zapInPool, routeA, routeB, User2.addr, true);
        vm.stopPrank();
        assertEq(IERC20(pool).balanceOf(gauge), lpTokens); // gauge has the lpTokens
    }
}
