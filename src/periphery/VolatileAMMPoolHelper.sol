// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolHelper} from "../interfaces/radiant/IPoolHelper.sol";
import {IPoolFactory} from "../interfaces/aerodrome/IPoolFactory.sol";
import {IPool} from "../interfaces/aerodrome/IPool.sol";
import {IRouter} from "../interfaces/aerodrome/IRouter.sol";
import {HomoraMath} from "../reference/libraries/HomoraMath.sol";

struct VolatileAMMPoolHelperInitParams {
    address pairToken;
    address weth9;
    uint256 amountPaired;
    uint256 amountWeth9;
    address routerAddr;
    address poolFactory;
}

contract VolatileAMMPoolHelper is IPoolHelper {
    using SafeERC20 for IERC20;
    using HomoraMath for uint256;

    /// Constants
    uint256 private constant _EIGHT_DECIMALS = 1e8;
    uint256 private constant _FULL_BPS = 10_000;

    /// Custom Errors
    error VolatileAMMPoolHelper_addressZero();
    error VolatileAMMPoolHelper_amountZero();
    error VolatileAMMPoolHelper_sameAddress();
    error VolatileAMMPoolHelper_weth9PairRequired();
    error VolatileAMMPoolHelper_quoteFailed();

    address public immutable pairedToken;
    address public immutable weth9;
    address public immutable lpTokenAddr;
    address public immutable factory;
    IRouter public immutable router;

    constructor(VolatileAMMPoolHelperInitParams memory params) {
        _checkNoZeroAddress(params.routerAddr);
        _checkNoZeroAddress(params.poolFactory);
        _checkNoZeroAddress(params.pairToken);
        _checkNoZeroAddress(params.weth9);
        if (params.pairToken == params.weth9) revert VolatileAMMPoolHelper_sameAddress();

        pairedToken = params.pairToken;
        weth9 = params.weth9;
        factory = params.poolFactory;
        router = IRouter(params.routerAddr);

        address pool = _getPool(params.pairToken, params.weth9);

        if (pool == address(0)) {
            require(params.amountPaired > 0 && params.amountWeth9 > 0, VolatileAMMPoolHelper_amountZero());
            _transferFrom(params.pairToken, msg.sender, address(this), params.amountPaired);
            _transferFrom(params.weth9, msg.sender, address(this), params.amountWeth9);
            _forceApprove(params.pairToken, params.poolFactory, params.amountPaired);
            _forceApprove(params.weth9, params.poolFactory, params.amountWeth9);
            lpTokenAddr = _createPool(params, msg.sender);
        } else {
            lpTokenAddr = pool;
        }
    }

    /// View Functions

    /**
     * @notice Returns the reserves of the LP token, including token0 amount, token1 amount, and LP token supply
     */
    function getReserves()
        public
        view
        returns (uint256 pairedTokenReserve, uint256 weth9Reserve, uint256 lpTokenSupply)
    {
        (uint256 token0Amt, uint256 token1Amt,) = IPool(lpTokenAddr).getReserves();
        (pairedTokenReserve, weth9Reserve) =
            IPool(lpTokenAddr).token0() == pairedToken ? (token0Amt, token1Amt) : (token1Amt, token0Amt);
        lpTokenSupply = IERC20(lpTokenAddr).totalSupply();
    }

    /**
     * @notice Returns a quote of `pairedTokenAmount` in weth9 amount
     * @param pairedTokenAmount The amount of paired token to quote
     */
    function quoteFromToken(uint256 pairedTokenAmount) external view returns (uint256 weth9Amount) {
        return _quoteAmountOutRouterSingleHop(pairedToken, weth9, pairedTokenAmount);
    }

    function quoteWETH(uint256 lpAmount) external view returns (uint256 wethAmount) {
        (uint256 pairTokenAmt, uint256 weth9Amt, uint256 lpSupply) = getReserves();
        uint256 neededPairToken = (lpAmount * pairTokenAmt) / (lpAmount + lpSupply);
        // Velodrome vAMM does not support a `getAmountsIn()` method, therefore, we estimate with `getAmountsOut()`
        uint256 neededRdntInWeth = _quoteAmountOutRouterSingleHop(pairedToken, weth9, neededPairToken);
        uint256 neededWeth = ((weth9Amt - neededRdntInWeth) * lpAmount) / lpSupply;

        return neededWeth + neededRdntInWeth;
    }

    /**
     * @notice Returns a quote of WETH9 amount to pairToken
     * @param weth9Amount The amount of WETH9 to quote
     */
    function quoteWethToPairToken(uint256 weth9Amount) external view returns (uint256) {
        return _quoteAmountOutRouterSingleHop(weth9, pairedToken, weth9Amount);
    }

    /**
     * @notice Returns estimated LpTokenPrice according to external fair price of pairToken in WETH9
     * @param _pairTokenPriceInWeth9 fair reference price of pairToken in weth9 in 8 decimals
     * @dev Methodology from: UniV2 / SLP LP Token Price
     * Alpha Homora Fair LP Pricing Method (flash loan resistant)
     * https://cmichel.io/pricing-lp-tokens/
     * https://blog.alphafinance.io/fair-lp-token-pricing/
     * https://github.com/AlphaFinanceLab/alpha-homora-v2-contract/blob/master/contracts/oracle/UniswapV2Oracle.sol
     */
    function getLpPrice(uint256 _pairTokenPriceInWeth9) external view returns (uint256 lpPriceInWeth9) {
        (uint256 token0Reserve, uint256 token1Reserve, uint256 lpSupply) = getReserves();
        uint256 sqrtK = HomoraMath.sqrt(token0Reserve * token1Reserve).fdiv(lpSupply); // in 2**112

        // weth9 amount per unit of pairToken, decimals 8
        uint256 pxA = _pairTokenPriceInWeth9 * HomoraMath.TWO_POW_112; // in 2**112
        // weth9 to weth9 constant, decimals 8
        uint256 pxB = _EIGHT_DECIMALS * HomoraMath.TWO_POW_112; // in 2**112

        // fair tokenA amt: sqrtK * sqrt(pxB/pxA)
        // fair tokenB amt: sqrtK * sqrt(pxA/pxB)
        // fair lp price = 2 * sqrt(pxA * pxB)
        // split into 2 sqrts multiplication to prevent uint256 overflow (note the 2**112)
        uint256 result = (((sqrtK * 2 * (HomoraMath.sqrt(pxA))) / (2 ** 56)) * (HomoraMath.sqrt(pxB))) / (2 ** 56);
        lpPriceInWeth9 = result / HomoraMath.TWO_POW_112;
    }

    /// Core functions

    function zapWETH(uint256 amount) external returns (uint256) {
        ////// TODO
        //     /// @dev Struct containing information necessary to zap in and out of pools
        // /// @param tokenA           .
        // /// @param tokenB           .
        // /// @param stable           Stable or volatile pool
        // /// @param factory          factory of pool
        // /// @param amountOutMinA    Minimum amount expected from swap leg of zap via routesA
        // /// @param amountOutMinB    Minimum amount expected from swap leg of zap via routesB
        // /// @param amountAMin       Minimum amount of tokenA expected from liquidity leg of zap
        // /// @param amountBMin       Minimum amount of tokenB expected from liquidity leg of zap
        // struct Zap {
        //     address tokenA;
        //     address tokenB;
        //     bool stable;
        //     address factory;
        //     uint256 amountOutMinA;
        //     uint256 amountOutMinB;
        //     uint256 amountAMin;
        //     uint256 amountBMin;
        // }
        // (uint256 pairTokenAmt, uint256 weth9Amt, uint256 liquidity) = _quoteAddLiquidity(0, amount);
        // IRouter.Zap memory zap = IRouter.Zap({
        //     tokenA: weth9,
        //     tokenB: pairedToken,
        //     stable: false,
        //     factory: factory,
        //     amountOutMinA: 0,
        //     amountOutMinB: 0,
        //     amountAMin: 0,
        //     amountBMin: 0
        // });
    }

    function zapTokens(uint256 _token0Amt, uint256 _token1Amt) external returns (uint256) {
        // TODO
    }

    function swapWethToRdnt(uint256 _wethAmount, uint256 _minAmountOut) external returns (uint256) {
        // TODO
    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function _forceApprove(address token, address operator, uint256 amount) internal {
        IERC20(token).forceApprove(operator, amount);
    }

    function _getPool(address tokenA, address tokenB) internal view returns (address) {
        return IPoolFactory(factory).getPool(tokenA, tokenB, false);
    }

    function _quoteAmountOutRouterSingleHop(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        IRouter.Route[] memory routes = new IRouter.Route[](1);
        routes[0] = IRouter.Route({from: tokenIn, to: tokenOut, stable: false, factory: factory});
        uint256[] memory amountsOut = router.getAmountsOut(amountIn, routes);
        if (amountsOut.length == 0) revert VolatileAMMPoolHelper_quoteFailed();
        return amountsOut[amountsOut.length - 1];
    }

    function _quoteAddLiquidity(uint256 pairTokenAmt, uint256 weth9Amt)
        internal
        view
        returns (uint256 quotePairTokenIn, uint256 quoteWethIn, uint256 liquidity)
    {
        (quotePairTokenIn, quoteWethIn, liquidity) =
            router.quoteAddLiquidity(pairedToken, weth9, false, factory, pairTokenAmt, weth9Amt);
    }

    function _createPool(VolatileAMMPoolHelperInitParams memory params, address caller)
        internal
        returns (address pool)
    {
        router.addLiquidity(
            params.pairToken,
            params.weth9,
            false,
            params.amountPaired,
            params.amountWeth9,
            _calculateReducedAmount(params.amountPaired, 100),
            _calculateReducedAmount(params.amountWeth9, 100),
            caller,
            block.timestamp
        );
        return _getPool(params.pairToken, params.weth9);
    }

    function _calculateReducedAmount(uint256 amount, uint256 reducedByBps) internal pure returns (uint256) {
        return (amount * (_FULL_BPS - reducedByBps)) / _FULL_BPS;
    }

    function _checkNoZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert VolatileAMMPoolHelper_addressZero();
    }
}
