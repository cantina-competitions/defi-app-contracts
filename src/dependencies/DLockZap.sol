// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DustRefunder} from "./helpers/DustRefunder.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UAccessControlUpgradeable} from "./UAccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IMultiFeeDistribution} from "../interfaces/radiant/IMultiFeeDistribution.sol";
import {ILendingPool, DataTypes} from "../interfaces/radiant/ILendingPool.sol";
import {IPoolHelper} from "../interfaces/radiant/IPoolHelper.sol";
import {IPriceProvider} from "../interfaces/radiant/IPriceProvider.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {TransferHelper} from "./helpers/TransferHelper.sol";
import {IOracleRouter} from "../interfaces/radiant/IOracleRouter.sol";
// import {IUniswapRouter, IUniwsapV3Router, IUniswapV3Quoter} from "../../interfaces/uniswap/IUniswapRouter.sol";

/// @title LockZap contract
/// @author security@defi.app
contract DLockZap is Initializable, UAccessControlUpgradeable, PausableUpgradeable, DustRefunder, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    struct ZapParams {
        bool borrow;
        address lendingPool;
        address asset;
        uint256 assetAmt;
        uint256 emissionTokenAmt;
        address from;
        address onBehalf;
        uint256 lockTypeIndex;
        address refundAddress;
        uint256 slippage;
    }

    /// Events

    event Zapped(
        bool _borrow,
        uint256 _ethAmt,
        uint256 _emissionTokenAmt,
        address indexed _from,
        address indexed _onBehalf,
        uint256 _lockTypeIndex
    );
    event PriceProviderUpdated(address indexed _provider);
    event MfdUpdated(address indexed _mfdAddr);
    event PoolHelperUpdated(address indexed _poolHelper);
    event lpRatioUpdated(uint256 _lpRatio);
    event UniRouterUpdated(address indexed _uniRouter);
    event RoutesUniV3Updated(address indexed _tokenIn, address indexed _tokenOut, bytes _route);
    event UniV3QuoterUpdated(address indexed _uniV3Quoter);
    event OracleRouterUpdated(address indexed _oracleRouter);

    /// Custom Errors
    error DLockZap_addressZero();
    error DLockZap_amountZero();
    error DLockZap_invalidRatio();
    error DLockZap_invalidLendingPool();
    error DLockZap_specifiedSlippageExceedLimit();
    error DLockZap_receivedETHOnAlternativeAssetZap();
    error DLockZap_invalidZapETHSource();
    error DLockZap_insufficientETH();
    error DLockZap_slippageTooHigh();

    uint256 public constant MAX_SLIPPAGE = 9500; // 5%, the maximum amount of slippage that a user can set for the execution of Zaps
    uint256 public constant RATIO_DIVISOR = 10_000;
    uint256 public constant BASE_PERCENT = 100;
    uint256 public constant VARIABLE_INTEREST_RATE_MODE = 2;
    uint16 public constant REFERRAL_CODE = 0;

    uint256 private constant MIN_UNIV3_ROUTE_LENGTH = 43; // The minimum length of a Uniswap V3 route
    uint256 private constant UNIV3_NEXT_OFFSET = 23; // The offset of the next address in a Uniswap V3 route
    uint256 private constant _ADDR_SIZE = 20;

    /// @notice Wrapped ETH
    IWETH9 public weth;

    /// @notice emissionToken token address
    address public emissionTokenAddr;

    /// @notice Multi Fee distribution contract
    IMultiFeeDistribution public mfd;

    /// @notice Pool helper contract used for emissionToken-WETH swaps
    IPoolHelper public poolHelper;

    /// @notice Price provider contract
    IPriceProvider public priceProvider;

    /// @notice Oracle Router contract
    IOracleRouter public oracleRouter;

    /// @notice parameter to set the ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
    uint256 public lpRatio;

    /// @notice AMM router used for all non emissionToken-WETH swaps on Arbitrum
    address public uniRouter;

    /// @notice Swap uniswap v3 routes from token0 to token1
    mapping(address => mapping(address => bytes)) internal _uniV3Route;

    mapping(address => bool) public approvedLendingPool;

    address public uniV3Quoter;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param _poolHelper Pool helper address used for emissionToken-WETH swaps
     * @param _uniRouter UniV2 router address used for all non emissionToken-WETH swaps
     * @param _lendingPool Lending pool
     * @param _weth weth address
     * @param _emissionTokenAddr emissionToken token address
     * @param _lpRatio ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
     * @param _oracleRouter Oracle router address
     */
    function initialize(
        IPoolHelper _poolHelper,
        address _uniRouter,
        ILendingPool _lendingPool,
        IWETH9 _weth,
        address _emissionTokenAddr,
        uint256 _lpRatio,
        IOracleRouter _oracleRouter
    ) external initializer {
        if (address(_poolHelper) == address(0)) revert DLockZap_addressZero();
        if (address(_uniRouter) == address(0)) revert DLockZap_addressZero();
        if (address(_lendingPool) == address(0)) revert DLockZap_addressZero();
        if (address(_weth) == address(0)) revert DLockZap_addressZero();
        if (_emissionTokenAddr == address(0)) revert DLockZap_addressZero();
        if (_lpRatio == 0 || _lpRatio >= RATIO_DIVISOR) revert DLockZap_invalidRatio();
        if (address(_oracleRouter) == address(0)) revert DLockZap_addressZero();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        poolHelper = _poolHelper;
        uniRouter = _uniRouter;
        weth = _weth;
        emissionTokenAddr = _emissionTokenAddr;
        lpRatio = _lpRatio;
        oracleRouter = _oracleRouter;
    }

    receive() external payable {}

    /**
     * @notice Pause zapping operation.
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause zapping operation.
     */
    function unpause() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    /**
     * @notice Allows owner to recover ETH locked in this contract.
     * @param to ETH receiver
     * @param value ETH amount
     */
    function withdrawLockedETH(address to, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TransferHelper.safeTransferETH(to, value);
    }

    /**
     * @notice Set the ratio of ETH in the LP token
     * @dev The ratio typically doesn't change, but this function is provided for flexibility
     * when using with UniswapV3 in where the ratio can be different.
     * @param _lpRatio ratio of ETH in the LP token, (example: can be 2000 for an 80/20 lp)
     */
    function setlpRatio(uint256 _lpRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_lpRatio == 0 || _lpRatio >= RATIO_DIVISOR) revert DLockZap_invalidRatio();
        lpRatio = _lpRatio;
        emit lpRatioUpdated(_lpRatio);
    }

    /**
     * @notice Set Price Provider.
     * @param _provider Price provider contract address.
     */
    function setPriceProvider(address _provider) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_provider == address(0)) revert DLockZap_addressZero();
        priceProvider = IPriceProvider(_provider);
        emit PriceProviderUpdated(_provider);
    }

    /// @notice Set Oracle Router.
    /// @param _oracleRouter Oracle router contract address.
    function setOracleRouter(address _oracleRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oracleRouter == address(0)) revert DLockZap_addressZero();
        if (oracleRouter != IOracleRouter(_oracleRouter)) {
            oracleRouter = IOracleRouter(_oracleRouter);
            emit OracleRouterUpdated(_oracleRouter);
        }
    }

    /**
     * @notice Set Multi fee distribution contract.
     * @param _mfdAddr New contract address.
     */
    function setMfd(address _mfdAddr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_mfdAddr == address(0)) revert DLockZap_addressZero();
        mfd = IMultiFeeDistribution(_mfdAddr);
        emit MfdUpdated(_mfdAddr);
    }

    /**
     * @notice Set Pool Helper contract used fror WETH-emissionToken swaps
     * @param _poolHelper New PoolHelper contract address.
     */
    function setPoolHelper(address _poolHelper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_poolHelper == address(0)) revert DLockZap_addressZero();
        poolHelper = IPoolHelper(_poolHelper);
        emit PoolHelperUpdated(_poolHelper);
    }

    /**
     * @notice Set swap router
     * @param _uniRouter Address of swap router
     */
    function setUniRouter(address _uniRouter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_uniRouter == address(0)) revert DLockZap_addressZero();
        if (uniRouter != _uniRouter) {
            uniRouter = _uniRouter;
            emit UniRouterUpdated(_uniRouter);
        }
    }

    /**
     * @notice Set UniswapV3 Quoter
     * @param _uniV3Quoter address of the UniswapV3 Quoter
     * @dev Suggest to use static quoter by eden network on production
     * https://github.com/eden-network/uniswap-v3-static-quoter
     */
    function setUniV3Quoter(address _uniV3Quoter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_uniV3Quoter == address(0)) revert DLockZap_addressZero();
        // uniV3Quoter = IQuoter(_uniV3Quoter);
        // TODO: complete decision on _safeSwap
        emit UniV3QuoterUpdated(_uniV3Quoter);
    }

    /**
     * @notice Set UniswapV3 swap routes
     * @param _tokenIn Token to swap
     * @param _tokenOut Token to receive
     * @param _route Swap route for token
     */
    function setUniV3Route(address _tokenIn, address _tokenOut, bytes memory _route)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        /// TODO see _safeSwap
        if (_tokenIn == address(0) || _tokenOut == address(0)) revert DLockZap_addressZero();
        // 43 is the minimum length of a UniswapV3 route with encodePacked.
        // (20 bytes) _tokenIn + (3 bytes) poolFee as uint24 + (20 bytes) _tokenOut
        // uint256 routeLength = _route.length;
        // if (routeLength < MIN_UNIV3_ROUTE_LENGTH && (routeLength - _ADDR_SIZE) % UNIV3_NEXT_OFFSET != 0) {
        //     revert Errors.WrongRoute(_tokenIn, _tokenOut);
        // }
        // _uniV3Route[_tokenIn][_tokenOut] = _route;
        emit RoutesUniV3Updated(_tokenIn, _tokenOut, _route);
    }

    /**
     * @notice Returns the stored swap route for UniswapV2 for the given tokens
     */
    function getUniV3Route(address _tokenIn, address _tokenOut) external view returns (bytes memory) {
        return _uniV3Route[_tokenIn][_tokenOut];
    }

    /**
     * @notice Get Variable debt token address
     * @param _asset underlying.
     */
    function getVDebtToken(address _asset, ILendingPool lendingPool) external view returns (address) {
        DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(_asset);
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @notice Calculate amount of specified `token` to be paired with amount of `_emissionTokenIn`.
     * DO NOT CALL THIS FUNCTION FROM AN EXTERNAL CONTRACT; REFER TO THE FOLLOWING LINK FOR MORE INFORMATION:
     * https://github.com/Uniswap/v3-periphery/blob/464a8a49611272f7349c970e0fadb7ec1d3c1086/contracts/lens/Quoter.sol#L18
     *
     * @param _token address of the token that would be received
     * @param _emissionTokenIn of emissionToken to be sold
     * @return amount of _token received
     *
     * @dev This function is mainly used to calculate how much of the specified token is needed to match the provided
     * emissionToken amount when providing liquidity to an AMM.
     */
    function quoteFromToken(address _token, uint256 _emissionTokenIn) public returns (uint256) {
        address weth_ = address(weth);
        if (_token != weth_) {
            uint256 wethAmount = poolHelper.quoteFromToken(_emissionTokenIn);
            return _quoteUniswap(_token, weth_, wethAmount);
        }
        return poolHelper.quoteFromToken(_emissionTokenIn);
    }

    /**
     * @notice Zap tokens to stake LP
     * @param _borrow option to borrow ETH
     * @param _lendingPool lending pool address to be used for zapping. Use only Riz lending pools
     * @param _asset to be used for zapping
     * @param _assetAmt amount of weth.
     * @param _emissionTokenAmt amount of emissionToken.
     * @param _lockTypeIndex lock length index.
     * @param _slippage maximum amount of slippage allowed for any occurring trades
     * @return LP amount
     */
    function zap(
        bool _borrow,
        address _lendingPool,
        address _asset,
        uint256 _assetAmt,
        uint256 _emissionTokenAmt,
        uint256 _lockTypeIndex,
        uint256 _slippage
    ) public payable whenNotPaused returns (uint256) {
        if (!approvedLendingPool[_lendingPool]) revert DLockZap_invalidLendingPool();
        ZapParams memory params = ZapParams({
            borrow: _borrow,
            lendingPool: _lendingPool,
            asset: _asset,
            assetAmt: _assetAmt,
            emissionTokenAmt: _emissionTokenAmt,
            from: msg.sender,
            onBehalf: msg.sender,
            lockTypeIndex: _lockTypeIndex,
            refundAddress: msg.sender,
            slippage: _slippage
        });
        return _zap(params);
    }

    /**
     * @notice Riz Zap tokens to stake LP
     * @dev It will use default lock index
     * @param _borrow option to borrow ETH
     * @param _lendingPool lending pool address to be used for zapping. Use only Riz lending pools
     * @param _asset to be used for zapping
     * @param _assetAmt amount of weth.
     * @param _emissionTokenAmt amount of emissionToken.
     * @param _onBehalf user address to be zapped.
     * @param _slippage maximum amount of slippage allowed for any occurring trades
     * @return LP amount
     */
    function zapOnBehalf(
        bool _borrow,
        address _lendingPool,
        address _asset,
        uint256 _assetAmt,
        uint256 _emissionTokenAmt,
        address _onBehalf,
        uint256 _slippage
    ) public payable whenNotPaused returns (uint256) {
        if (!approvedLendingPool[_lendingPool]) revert DLockZap_invalidLendingPool();
        uint256 duration = mfd.getDefaultLockIndex(_onBehalf);
        ZapParams memory params = ZapParams({
            borrow: _borrow,
            lendingPool: _lendingPool,
            asset: _asset,
            assetAmt: _assetAmt,
            emissionTokenAmt: _emissionTokenAmt,
            from: msg.sender,
            onBehalf: _onBehalf,
            lockTypeIndex: duration,
            refundAddress: msg.sender,
            slippage: _slippage
        });
        return _zap(params);
    }

    /**
     * @notice Calculates slippage ratio from usd value to LP
     * @param _assetValueUsd amount in USD used to create LP pair
     * @param _liquidity LP token amount
     */
    function _calcSlippage(uint256 _assetValueUsd, uint256 _liquidity) internal returns (uint256 ratio) {
        priceProvider.update();
        // Scale price provider price to 1e18, as priceProvider always returns price scaled to 1e8.
        // This was okay for the core markets as _assetValueUsd was scaled to 1e8, but Riz markets
        // Introduced OracleRouter that always returns price scaled to 1e18, so we need to scale the priceProvider price
        uint256 lpTokenPriceUsd = priceProvider.getLpTokenPriceUsd() * 1e10;
        uint256 lpAmountValueUsd = (_liquidity * lpTokenPriceUsd) / 1e18;
        ratio = (lpAmountValueUsd * (RATIO_DIVISOR)) / (_assetValueUsd);
    }

    /**
     * @notice Zap into LP
     * @param params ZapParams struct
     */
    function _zap(ZapParams memory params) internal returns (uint256 liquidity) {
        if (params.lendingPool == address(0)) revert DLockZap_addressZero();
        IWETH9 weth_ = weth;
        if (params.asset == address(0)) {
            params.asset = address(weth_);
        }
        if (params.slippage == 0) {
            params.slippage = MAX_SLIPPAGE;
        } else {
            if (MAX_SLIPPAGE > params.slippage || params.slippage > RATIO_DIVISOR) {
                revert DLockZap_specifiedSlippageExceedLimit();
            }
        }
        bool isAssetWeth = params.asset == address(weth_);

        // Handle pure ETH
        if (msg.value > 0) {
            if (!isAssetWeth) revert DLockZap_receivedETHOnAlternativeAssetZap();
            if (params.borrow) revert DLockZap_invalidZapETHSource();
            params.assetAmt = msg.value;
            weth_.deposit{value: params.assetAmt}();
        }
        if (params.assetAmt == 0) revert DLockZap_amountZero();
        uint256 assetAmountValueUsd = (params.assetAmt * oracleRouter.getAssetPrice(params.asset))
            / (10 ** IERC20Metadata(params.asset).decimals());

        // Handle borrowing logic
        if (params.borrow) {
            // Borrow the asset on the users behalf
            ILendingPool(params.lendingPool).borrow(
                params.asset, params.assetAmt, VARIABLE_INTEREST_RATE_MODE, REFERRAL_CODE, msg.sender
            );

            // If asset isn't WETH, swap for WETH
            if (!isAssetWeth) {
                params.assetAmt = _safeSwap(params.asset, address(weth_), params.assetAmt, 0);
            }
        } else if (msg.value == 0) {
            // Transfer asset from user
            IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.assetAmt);
            if (!isAssetWeth) {
                params.assetAmt = _safeSwap(params.asset, address(weth_), params.assetAmt, 0);
            }
        }

        weth_.approve(address(poolHelper), params.assetAmt);
        //case where emissionToken is matched with provided ETH
        if (params.emissionTokenAmt != 0) {
            if (params.assetAmt < poolHelper.quoteFromToken(params.emissionTokenAmt)) revert DLockZap_insufficientETH();
            // _from == this when zapping from vesting
            if (params.from != address(this)) {
                IERC20(emissionTokenAddr).safeTransferFrom(msg.sender, address(this), params.emissionTokenAmt);
            }

            IERC20(emissionTokenAddr).forceApprove(address(poolHelper), params.emissionTokenAmt);
            liquidity = poolHelper.zapTokens(params.assetAmt, params.emissionTokenAmt);
            assetAmountValueUsd = (assetAmountValueUsd * RATIO_DIVISOR) / lpRatio;
        } else {
            liquidity = poolHelper.zapWETH(params.assetAmt);
        }

        if (address(priceProvider) != address(0)) {
            if (_calcSlippage(assetAmountValueUsd, liquidity) < params.slippage) revert DLockZap_slippageTooHigh();
        }

        IERC20(poolHelper.lpTokenAddr()).forceApprove(address(mfd), liquidity);
        mfd.stake(liquidity, params.onBehalf, params.lockTypeIndex);
        emit Zapped(
            params.borrow, params.assetAmt, params.emissionTokenAmt, params.from, params.onBehalf, params.lockTypeIndex
        );

        _refundDust(emissionTokenAddr, params.refundAddress);
        _refundDust(params.asset, params.refundAddress);
    }

    /**
     * @dev Internal function that handles general swaps and can be used safely in loops to throw if
     * an intermediate swap fails
     * @param _tokenIn to be swapped
     * @param _tokenOut to be received
     * @param _amountIn to swap
     * @param _amountOutMin expected
     */
    function _safeSwap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOutMin)
        internal
        returns (uint256)
    {
        /// TODO: find best way to swap
        // IERC20(_tokenIn).forceApprove(uniRouter, _amountIn);
        // bytes memory route = _uniV3Route[_tokenIn][_tokenOut];
        // try IUniswapRouter(uniRouter).exactInput(
        //     ISwapRouter.ExactInputParams({
        //         path: route,
        //         recipient: address(this),
        //         deadline: block.timestamp,
        //         amountIn: _amountIn,
        //         amountOutMinimum: _amountOutMin
        //     })
        // ) returns (uint256 amountOut) {
        //     return amountOut;
        // } catch {
        //     revert Errors.SwapFailed(_tokenIn, _amountIn);
        // }
    }

    /**
     * @dev Internal function to get `amountIn` from an exact output in UniswapV3.
     * @param _tokenIn to be swapped
     * @param _tokenOut to be received
     * @param _amountOut expected to be received
     * @return amountInRequired to get _amountOut
     */
    function _quoteUniswap(address _tokenIn, address _tokenOut, uint256 _amountOut)
        internal
        returns (uint256 amountInRequired)
    {
        // TODO see simpleSwap
        // NOTE!: For `quoteExactOutput` the path must be provided in reverse order:
        // i.e. _tokenOut -> _tokenIn
        // return uniV3Quoter.quoteExactOutput(_uniV3Route[_tokenOut][_tokenIn], _amountOut);
    }

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}
}
