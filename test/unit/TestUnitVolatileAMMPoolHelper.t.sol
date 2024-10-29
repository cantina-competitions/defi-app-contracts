// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../script/foundry/deploy-libraries/_Index.s.sol";
import {BasicFixture, MockToken} from "../BasicFixture.t.sol";
import {console} from "forge-std/console.sol";
import {VolatileAMMPoolHelper, VolatileAMMPoolHelperInitParams} from "../../src/periphery/VolatileAMMPoolHelper.sol";
import {MockToken, ERC20} from "../mocks/MockToken.t.sol";
import {
    MockAerodromeFixture,
    MockPool,
    MockPoolFactory,
    MockRouter,
    MockVoter
} from "../mocks/aerodrome/MockAerodromeFixture.t.sol";
import {IVoter} from "../../src/interfaces/aerodrome/IVoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestUnitVolatileAMMPoolHelper is MockAerodromeFixture {
    VolatileAMMPoolHelper public vAmmPoolHelper;

    MockToken public emissionToken;
    MockToken public weth9;
    MockPoolFactory public poolFactory;
    MockRouter public router;

    address public constant ZAPPER = address(1280);

    uint256 public constant INITIAL_WETH9_AMT = 1000 ether;
    uint256 public constant INITIAL_PAIR_AMT = 2_500_000 ether;
    // INIT_PRICE = (emitToken / weth9); in 8 decimals
    uint256 public constant INIT_PRICE = (INITIAL_PAIR_AMT * 1e8) / INITIAL_WETH9_AMT;

    function setUp() public override {
        super.setUp();
        weth9 = deploy_mock_tocken("Mock Weth9", "WETH9");
        emissionToken = deploy_mock_tocken("Test Home", "tsHOME");

        vm.label(address(emissionToken), "HomeToken");
        vm.label(address(weth9), "Weth9");

        (address poolFactory_, address router_) = deploy_mock_aerodrome(Admin.addr, address(weth9));
        poolFactory = MockPoolFactory(poolFactory_);
        router = MockRouter(payable(router_));

        // Deploy VolatileAMMPoolHelper
        VolatileAMMPoolHelperInitParams memory initParams = VolatileAMMPoolHelperInitParams({
            pairToken: address(emissionToken),
            weth9: address(weth9),
            amountPaired: INITIAL_PAIR_AMT,
            amountWeth9: INITIAL_WETH9_AMT,
            routerAddr: address(router),
            poolFactory: address(poolFactory)
        });

        emissionToken.mint(Admin.addr, INITIAL_PAIR_AMT);
        weth9.mint(Admin.addr, INITIAL_PAIR_AMT);

        vm.startPrank(Admin.addr);
        vAmmPoolHelper = VolatileAMMPoolHelperDeployer.deploy(fs, "vAMMPoolHelper", TESTING_ONLY, initParams);
        vm.stopPrank();

        create_gauge(Admin.addr, address(emissionToken), address(weth9), address(poolFactory));
    }

    function test_mockAerodromeSetUp() public {
        _testMockAerodromeIsFunctional(poolFactory, router);
    }

    function test_vAMMPoolHelperIsInitializedProperly() public view {
        assertEq(address(vAmmPoolHelper) != address(0), true);
        assertEq(vAmmPoolHelper.pairToken(), address(emissionToken));
        assertEq(vAmmPoolHelper.weth9(), address(weth9));
        assertEq(address(vAmmPoolHelper.router()), address(router));
        assertEq(vAmmPoolHelper.factory(), address(poolFactory));

        address pool = vAmmPoolHelper.lpTokenAddr();
        assertEq(pool != address(0), true);
        assertEq(emissionToken.balanceOf(pool), INITIAL_PAIR_AMT);
        assertEq(weth9.balanceOf(pool), INITIAL_WETH9_AMT);
    }

    function test_vAMMPoolHelperCannotBeReinitialized() public {
        emissionToken.mint(Admin.addr, INITIAL_PAIR_AMT);
        weth9.mint(Admin.addr, INITIAL_PAIR_AMT);
        VolatileAMMPoolHelperInitParams memory initParams = VolatileAMMPoolHelperInitParams({
            pairToken: address(emissionToken),
            weth9: address(weth9),
            amountPaired: INITIAL_PAIR_AMT,
            amountWeth9: INITIAL_WETH9_AMT,
            routerAddr: address(router),
            poolFactory: address(poolFactory)
        });
        vm.prank(Admin.addr);
        vm.expectRevert();
        vAmmPoolHelper.initialize(initParams);
    }

    function test_vAMMPoolHelperGetReserves() public view {
        (uint256 pairTokenAmt, uint256 weth9Amt,) = vAmmPoolHelper.getReserves();
        assertEq(pairTokenAmt, INITIAL_PAIR_AMT);
        assertEq(weth9Amt, INITIAL_WETH9_AMT);
    }

    function test_vAMMPoolHelperQuoteFromToken() public view {
        uint256 amountPairTokenIn = 2500 ether;
        uint256 expectedAmountOut = vAmmPoolHelper.quoteFromToken(amountPairTokenIn);
        uint256 within75Bps = calculate_reduced_amount(expectedAmountOut, 9925);
        assertApproxEqAbs(expectedAmountOut, (amountPairTokenIn * 1e8) / INIT_PRICE, within75Bps);
    }

    function test_vAMMPoolHelperQuoteWETH() public view {
        (,, uint256 lpTotalSupply) = vAmmPoolHelper.getReserves();
        uint256 wethRequired = vAmmPoolHelper.quoteWETH(lpTotalSupply);
        assertEq(wethRequired > 0, true);
    }

    function test_vAMMPoolHelperQuoteWethToPairToken() public view {
        uint256 amountWETHIn = 1 ether;
        uint256 expectedAmountOut = vAmmPoolHelper.quoteWethToPairToken(amountWETHIn);
        uint256 within75Bps = calculate_reduced_amount(expectedAmountOut, 9925);
        assertApproxEqAbs(expectedAmountOut, (amountWETHIn * INIT_PRICE) / 1e8, within75Bps);
    }

    function test_vAMMPoolHelperGetLpPrice() public view {
        uint256 pairTokenPriceInWeth9 = 1e16 / INIT_PRICE;
        uint256 lpPrice = vAmmPoolHelper.getLpPrice(pairTokenPriceInWeth9);
        (,, uint256 lpTotalSupply) = vAmmPoolHelper.getReserves();
        uint256 expectedLpPrice = (2 * INITIAL_WETH9_AMT * 1e8) / lpTotalSupply;
        assertEq(lpPrice, expectedLpPrice);
    }

    function test_vAMMPoolHelperSetAllowedZapperPermission(address foe) public {
        vm.assume(foe != address(0) && foe != Admin.addr);
        vm.prank(Admin.addr);
        vAmmPoolHelper.setAllowedZapper(ZAPPER, true);
        assertEq(vAmmPoolHelper.allowedZappers(ZAPPER), true);

        vm.prank(foe);
        vm.expectRevert();
        vAmmPoolHelper.setAllowedZapper(ZAPPER, false);
        assertEq(vAmmPoolHelper.allowedZappers(ZAPPER), true); // no change
    }

    function test_vAMMPoolHelperSetDefaultSlippage(uint16 slippage) public {
        uint256 current = vAmmPoolHelper.defaultSlippage();

        if (slippage > 10_000) {
            vm.expectRevert();
            vm.prank(Admin.addr);
            vAmmPoolHelper.setDefaultSlippage(slippage);
            assertEq(vAmmPoolHelper.defaultSlippage(), current);
            return;
        }

        if (slippage == current) {
            vm.expectRevert();
            vm.prank(Admin.addr);
            vAmmPoolHelper.setDefaultSlippage(slippage);
            assertEq(vAmmPoolHelper.defaultSlippage(), current);
            return;
        }

        vm.prank(Admin.addr);
        vAmmPoolHelper.setDefaultSlippage(slippage);
        assertEq(vAmmPoolHelper.defaultSlippage(), slippage);
    }

    function test_vAMMPoolHelperSetDefaultSlippagePermission(address foe) public {
        vm.assume(foe != address(0) && foe != Admin.addr);
        vm.prank(foe);
        vm.expectRevert();
        vAmmPoolHelper.setDefaultSlippage(5000);
    }

    function test_vAMMPoolHelperZapWeth() public {
        set_zapper(User1.addr);

        uint256 amount = 1 ether;
        address pool = vAmmPoolHelper.lpTokenAddr();
        assertEq(IERC20(pool).balanceOf(User1.addr), 0);

        weth9.mint(User1.addr, amount);

        vm.startPrank(User1.addr);
        weth9.approve(address(vAmmPoolHelper), amount);
        uint256 lpTokens = vAmmPoolHelper.zapWETH(amount);
        vm.stopPrank();

        address gauge = IVoter(router.voter()).gauges(pool);
        uint256 gaugeBalanceOfZapper = IERC20(gauge).balanceOf(User1.addr);
        assertEq(gaugeBalanceOfZapper > 0, true);
        assertEq(gaugeBalanceOfZapper, lpTokens);
    }

    function set_zapper(address zapper) internal {
        vm.prank(Admin.addr);
        vAmmPoolHelper.setAllowedZapper(zapper, true);
    }

    function calculate_reduced_amount(uint256 amount, uint256 reducedByBps) internal pure returns (uint256) {
        uint256 fullBps = 10_000; // 100%
        return (amount * (fullBps - reducedByBps)) / fullBps;
    }
}
