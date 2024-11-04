// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolHelper} from "../interfaces/radiant/IPoolHelper.sol";
import {IPoolFactory} from "../interfaces/aerodrome/IPoolFactory.sol";
import {IPool} from "../interfaces/aerodrome/IPool.sol";
import {IRouter} from "../interfaces/aerodrome/IRouter.sol";
import {IGauge} from "../interfaces/aerodrome/IGauge.sol";
import {IVoter} from "../interfaces/aerodrome/IVoter.sol";
import {DustRefunder} from "../dependencies/helpers/DustRefunder.sol";
import {HomoraMath} from "../dependencies/libraries/HomoraMath.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

struct VolatileAMMPoolHelperInitParams {
    address pairToken;
    address weth9;
    uint256 amountPaired;
    uint256 amountWeth9;
    address routerAddr;
    address poolFactory;
}

contract VolatileAMMPoolHelper is IPoolHelper, Initializable, DustRefunder, Ownable2Step {
    using SafeERC20 for IERC20;
    using HomoraMath for uint256;

    /// Events
    event DefaultSlippageSet(uint256 slippage);
    event ZapperSet(address indexed zapper, bool allowed);

    /// Custom Errors
    error VolatileAMMPoolHelper_addressZero();
    error VolatileAMMPoolHelper_amountZero();
    error VolatileAMMPoolHelper_sameAddress();
    error VolatileAMMPoolHelper_weth9PairRequired();
    error VolatileAMMPoolHelper_onlyAllowedZappers();
    error VolatileAMMPoolHelper_slippageExceedsMaximum();
    error VolatileAMMPoolHelper_noChange();
    error VolatileAMMPoolHelper_quoteFailed();
    error VolatileAMMPoolHelper_swapLessThanExpected();

    /// Constants
    uint256 private constant _EIGHT_DECIMALS = 1e8;
    uint256 private constant _BLOCK_INTERVAL = 2 seconds;
    uint256 private constant _FULL_BPS = 10_000;
    uint256 private constant _DEFAULT_SLIPPAGE = 25; // 25 bps

    address public pairToken;
    address public weth9;
    address public pool;
    address public factory;
    IRouter public router;

    uint256 public defaultSlippage;
    mapping(address => bool) public allowedZappers;

    modifier onlyZapper() {
        require(allowedZappers[msg.sender], VolatileAMMPoolHelper_onlyAllowedZappers());
        _;
    }

    constructor() Ownable(msg.sender) {}

    function initialize(VolatileAMMPoolHelperInitParams memory params) external initializer {
        _checkNoZeroAddress(params.routerAddr);
        _checkNoZeroAddress(params.poolFactory);
        _checkNoZeroAddress(params.pairToken);
        _checkNoZeroAddress(params.weth9);
        if (params.pairToken == params.weth9) revert VolatileAMMPoolHelper_sameAddress();

        pairToken = params.pairToken;
        weth9 = params.weth9;
        factory = params.poolFactory;
        router = IRouter(params.routerAddr);

        address pool_ = _getPool(params.pairToken, params.weth9);

        if (pool == address(0)) {
            require(params.amountPaired > 0 && params.amountWeth9 > 0, VolatileAMMPoolHelper_amountZero());
            _transferFrom(params.pairToken, msg.sender, address(this), params.amountPaired);
            _transferFrom(params.weth9, msg.sender, address(this), params.amountWeth9);
            _forceApprove(params.pairToken, params.routerAddr, params.amountPaired);
            _forceApprove(params.weth9, params.routerAddr, params.amountWeth9);
            pool = _createPool(params, msg.sender);
        } else {
            pool = pool_;
        }

        emit DefaultSlippageSet(_DEFAULT_SLIPPAGE);
    }

    /// View Functions

    function lpTokenAddr() public view returns (address) {
        return pool;
    }

    /**
     * @notice Returns the reserves of the LP token, including pairToken amount, weth9 amount, and LP token supply
     */
    function getReserves() public view returns (uint256 pairTokenAmt, uint256 weth9Amt, uint256 lpTokenSupply) {
        (uint256 token0Amt, uint256 token1Amt,) = IPool(pool).getReserves();
        (pairTokenAmt, weth9Amt) = IPool(pool).token0() == pairToken ? (token0Amt, token1Amt) : (token1Amt, token0Amt);
        lpTokenSupply = IERC20(pool).totalSupply();
    }

    /**
     * @notice Returns a quote of `pairTokenAmount` in weth9 amount
     * @param pairTokenAmount The amount of paired token to quote
     */
    function quoteFromToken(uint256 pairTokenAmount) external view returns (uint256 weth9Amount) {
        return _quoteSimpleOut(pairToken, pairTokenAmount);
    }

    /**
     * @notice Returns a quote of `weth9Amount` to pairToken amount
     * @param weth9Amount The amount of WETH9 to quote
     */
    function quoteFromWETH9(uint256 weth9Amount) external view returns (uint256 pairtTokenAmount) {
        return _quoteSimpleOut(weth9, weth9Amount);
    }

    /**
     * @notice Returns amount of weth9 required to get `lpAmount` of lpTokens.
     * @param lpAmount The amount of LP tokens to quote
     */
    function quoteWETH(uint256 lpAmount) external view returns (uint256 wethAmount) {
        (uint256 pairTokenAmt, uint256 weth9Amt, uint256 lpSupply) = getReserves();
        uint256 neededPairToken = (lpAmount * pairTokenAmt) / (lpAmount + lpSupply);
        uint256 neededPairInWeth9 = _quoteSimpleIn(pairToken, neededPairToken);
        uint256 neededWeth = ((weth9Amt - neededPairInWeth9) * lpAmount) / lpSupply;
        return neededWeth + neededPairInWeth9;
    }

    function quoteAddLiquidity(uint256 pairTokenAmt, uint256 weth9Amt)
        external
        view
        returns (uint256 pairTokenIn, uint256 weth9In, uint256 lpTokens)
    {
        if (pairTokenAmt == 0 && weth9Amt == 0) return (0, 0, 0);
        if (pairTokenAmt == 0 && weth9Amt > 0) {
            uint256 halfWeth9 = weth9Amt / 2;
            return
                router.quoteAddLiquidity(pairToken, weth9, false, factory, _quoteSimpleOut(weth9, halfWeth9), halfWeth9);
        }
        if (pairTokenAmt > 0 && weth9Amt == 0) {
            return router.quoteAddLiquidity(
                pairToken, weth9, false, factory, pairTokenAmt, _quoteSimpleOut(pairToken, pairTokenAmt)
            );
        } else {
            return router.quoteAddLiquidity(pairToken, weth9, false, factory, pairTokenAmt, weth9Amt);
        }
    }

    /**
     * @notice UNSAFE: returns `pairToken` price in weth9 from the pool reserves
     * @dev NOTE Use as an OFF_CHAIN VIEW METHOD ONLY
     * @return priceInEth 8 decimals price of `pairToken`
     */
    function getPrice() external view returns (uint256 priceInEth) {
        (uint256 pairTokenReserves, uint256 weth9Reserves,) = getReserves();
        if (pairTokenReserves > 0) {
            priceInEth = (weth9Reserves * (10 ** 8)) / pairTokenReserves;
        }
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
        (uint256 pairTokenAmt, uint256 weth9Amt, uint256 lpSupply) = getReserves();
        uint256 sqrtK = HomoraMath.sqrt(pairTokenAmt * weth9Amt).fdiv(lpSupply); // in 2**112

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

    function zapWETH(uint256 amount) external onlyZapper returns (uint256 lpTokens) {
        if (amount == 0) revert VolatileAMMPoolHelper_amountZero();
        _transferFrom(weth9, msg.sender, address(this), amount);
        _forceApprove(weth9, address(router), amount);

        IRouter.Route[] memory routeA = new IRouter.Route[](1);
        routeA[0] = IRouter.Route(weth9, pairToken, false, factory);
        IRouter.Route[] memory routeB = new IRouter.Route[](1);
        routeB[0] = IRouter.Route(pairToken, weth9, false, factory);

        uint256 halfWeth9 = amount / 2;

        IRouter.Zap memory zapInPool = IRouter.Zap(pairToken, weth9, false, factory, 0, 0, 0, 0);
        (zapInPool.amountOutMinA, zapInPool.amountOutMinB, zapInPool.amountAMin, zapInPool.amountBMin) = router
            .generateZapInParams(
            zapInPool.tokenA,
            zapInPool.tokenB,
            zapInPool.stable,
            zapInPool.factory,
            halfWeth9,
            halfWeth9,
            routeA,
            routeB
        );
        lpTokens = router.zapIn(weth9, halfWeth9, halfWeth9, zapInPool, routeA, routeB, msg.sender, false);

        _refundDust(pairToken, msg.sender);
        _refundDust(weth9, msg.sender);
    }

    /**
     * @dev This method will match up and `addToLiquidity` up to all pairAmt that can be matched.
     * It will NOT sell `pairToken` to match with `weth9`.
     * All unused `weth9` is returned.
     */
    function zapTokens(uint256 pairAmt, uint256 weth9Amt) external onlyZapper returns (uint256 lpTokens) {
        if (pairAmt == 0 && weth9Amt == 0) revert VolatileAMMPoolHelper_amountZero();
        _transferFrom(pairToken, msg.sender, address(this), pairAmt);
        _forceApprove(pairToken, address(router), pairAmt);
        _transferFrom(weth9, msg.sender, address(this), weth9Amt);
        _forceApprove(weth9, address(router), weth9Amt);

        // Match all possible `pairAmt`
        (uint256 amountA, uint256 amountB,) =
            router.quoteAddLiquidity(pairToken, weth9, false, factory, pairAmt, weth9Amt);
        (,, lpTokens) =
            router.addLiquidity(pairToken, weth9, false, pairAmt, amountB, amountA, amountB, msg.sender, _getDeadline());

        _refundDust(pairToken, msg.sender);
        _refundDust(weth9, msg.sender);
    }

    /// Setter Functions

    function setAllowedZapper(address zapper, bool allowed) external onlyOwner {
        _checkNoZeroAddress(zapper);
        bool currentStatus = allowedZappers[zapper];
        if (currentStatus == allowed) revert VolatileAMMPoolHelper_noChange();
        allowedZappers[zapper] = allowed;
        emit ZapperSet(zapper, allowed);
    }

    function setDefaultSlippage(uint256 slippage) external onlyOwner {
        require(slippage <= _FULL_BPS, VolatileAMMPoolHelper_slippageExceedsMaximum());
        if (defaultSlippage == slippage) revert VolatileAMMPoolHelper_noChange();
        defaultSlippage = slippage;
        emit DefaultSlippageSet(slippage);
    }

    /// Internal Functions

    function _swapSimple(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        _transfer(tokenIn, pool, amountIn);
        IERC20 tokenOut = IERC20(tokenIn == pairToken ? weth9 : pairToken);
        uint256 tokenOutPreCheck = tokenOut.balanceOf(address(this));
        (address token0, address token1) = _sortTokens(pairToken, weth9);
        IPool(pool).swap(
            tokenIn == token0 ? 0 : _quoteSimpleOut(tokenIn, amountIn),
            tokenIn == token1 ? 0 : _quoteSimpleOut(tokenIn, amountIn),
            address(this),
            new bytes(0)
        );
        uint256 tokenOutPostCheck = tokenOut.balanceOf(address(this));
        uint256 receivedTokenOut = tokenOutPostCheck - tokenOutPreCheck;
        if (receivedTokenOut < minAmountOut) revert VolatileAMMPoolHelper_swapLessThanExpected();
        return receivedTokenOut;
    }

    function _transfer(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function _forceApprove(address token, address operator, uint256 amount) internal {
        IERC20(token).forceApprove(operator, amount);
    }

    function _createPool(VolatileAMMPoolHelperInitParams memory params, address caller)
        internal
        returns (address newPool)
    {
        router.addLiquidity(
            params.pairToken,
            params.weth9,
            false,
            params.amountPaired,
            params.amountWeth9,
            _calculateReducedAmount(params.amountPaired, _DEFAULT_SLIPPAGE),
            _calculateReducedAmount(params.amountWeth9, _DEFAULT_SLIPPAGE),
            caller,
            _getDeadline()
        );
        newPool = _getPool(params.pairToken, params.weth9);
    }

    function _getPool(address tokenA, address tokenB) internal view returns (address) {
        return IPoolFactory(factory).getPool(tokenA, tokenB, false);
    }

    function _quoteSimpleOut(address tokenIn, uint256 amountIn) internal view returns (uint256 amountOut) {
        amountIn -= _estimatePoolFee(amountIn); // Remove fee from amountIn
        return _getAmountOut(tokenIn, amountIn);
    }

    function _quoteSimpleIn(address tokenOut, uint256 amountOut) internal view returns (uint256 amountIn) {
        uint256 amountInWithOutFee = _getAmountOut(tokenOut, amountOut);
        return amountInWithOutFee + _estimatePoolFee(amountInWithOutFee); // Add fee back to amountIn
    }

    function _getAmountOut(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        (uint256 pairTokenAmt, uint256 weth9Amt,) = getReserves();
        (uint256 reserveA, uint256 reserveB) = tokenIn == weth9 ? (weth9Amt, pairTokenAmt) : (pairTokenAmt, weth9Amt);
        return (amountIn * reserveB) / (reserveA + amountIn);
    }

    function _estimatePoolFee(uint256 amountIn) internal view returns (uint256) {
        return (amountIn * IPoolFactory(factory).getFee(pool, false)) / _FULL_BPS;
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address, address) {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _calculateReducedAmount(uint256 amount, uint256 reducedByBps) internal pure returns (uint256) {
        return (amount * (_FULL_BPS - reducedByBps)) / _FULL_BPS;
    }

    function _getDeadline() internal view returns (uint256) {
        return block.timestamp + _BLOCK_INTERVAL;
    }

    function _getSlippage() internal view returns (uint256) {
        return defaultSlippage == 0 ? _DEFAULT_SLIPPAGE : defaultSlippage;
    }

    function _checkNoZeroAddress(address _address) internal pure {
        if (_address == address(0)) revert VolatileAMMPoolHelper_addressZero();
    }
}
