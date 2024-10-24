// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DustRefunder} from "./helpers/DustRefunder.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IMultiFeeDistribution} from "../interfaces/radiant/IMultiFeeDistribution.sol";
import {ILendingPool, DataTypes} from "../interfaces/radiant/ILendingPool.sol";
import {IPoolHelper} from "../interfaces/radiant/IPoolHelper.sol";
import {IPriceProvider} from "../interfaces/radiant/IPriceProvider.sol";
import {IAaveOracle} from "../interfaces/radiant/IAaveOracle.sol";
import {IChainlinkAggregator} from "../interfaces/chainlink/IChainlinkAggregator.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IPriceOracle} from "../interfaces/radiant/IPriceOracle.sol";
import {TransferHelper} from "./helpers/TransferHelper.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

/// @title LockZap contract
/// @author security@defi.app
contract LockZap is Initializable, OwnableUpgradeable, PausableUpgradeable, DustRefunder, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The maximum amount of slippage that a user can set for the execution of Zaps
    /// @dev If the slippage limit of the LockZap contract is lower then that of the Compounder, transactions might fail unexpectedly.
    ///      Therefore ensure that this slippage limit is equal to that of the Compounder contract.
    uint256 public constant MAX_SLIPPAGE = 9500; // 5%

    /// @notice RATIO Divisor
    uint256 public constant RATIO_DIVISOR = 10000;

    /// @notice Base Percent
    uint256 public constant BASE_PERCENT = 100;

    /// @notice Borrow rate mode
    uint256 public constant VARIABLE_INTEREST_RATE_MODE = 2;

    /// @notice We don't utilize any specific referral code for borrows perfomed via zaps
    uint16 public constant REFERRAL_CODE = 0;

    uint256 public constant MIN_UNIV3_ROUTE_LENGTH = 43;
    uint256 public constant UNIV3_NEXT_OFFSET = 23;
    // No public getter for _ADDR_SIZE to reduce size
    uint256 internal constant _ADDR_SIZE = 20;

    /// @notice Wrapped ETH
    IWETH9 public weth;

    /// @notice RDNT token address
    address public rdntAddr;

    /// @notice Multi Fee distribution contract
    IMultiFeeDistribution public mfd;

    /// @notice Lending Pool contract
    ILendingPool public lendingPool;

    /// @notice Pool helper contract used for RDNT-WETH swaps
    IPoolHelper public poolHelper;

    /// @notice Price provider contract
    IPriceProvider public priceProvider;

    /// @notice aave oracle contract
    IAaveOracle public aaveOracle;

    /// @notice parameter to set the ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
    uint256 public ethLPRatio;

    /// @notice AMM router used for all non RDNT-WETH swaps on Arbitrum
    address public uniRouter;

    /// @notice Swap uniswap v3 routes from token0 to token1
    mapping(address => mapping(address => bytes)) internal _uniV3Route;

    IQuoter public uniV3Quoter;

    /**
     * Events **********************
     */
    /// @notice Emitted when zap is done
    event Zapped(
        bool _borrow,
        uint256 _ethAmt,
        uint256 _rdntAmt,
        address indexed _from,
        address indexed _onBehalf,
        uint256 _lockTypeIndex
    );

    event PriceProviderUpdated(address indexed _provider);

    event MfdUpdated(address indexed _mfdAddr);

    event PoolHelperUpdated(address indexed _poolHelper);

    /// @notice Emitted when ethLPRatio is updated
    event EthLPRatioUpdated(uint256 _ethLPRatio);

    /// @notice Emitted when UniswapV3 routes are updated
    event RoutesUniV3Updated(address indexed _tokenIn, address indexed _tokenOut, bytes _route);

    /// @notice Emitted when uniRouter is updated
    event UniRouterUpdated(address indexed _uniRouter);

    /// @notice Emitted when uniV3Quoter is updated
    event UniV3QuoterUpdated(address indexed _uniV3Quoter);

    /// Custom Errors
    error AddressZero();

    error InvalidRatio();

    error InvalidLockLength();

    error AmountZero();

    error SlippageTooHigh();

    error SpecifiedSlippageExceedLimit();

    error InvalidZapETHSource();

    error ReceivedETHOnAlternativeAssetZap();

    error InsufficientETH();

    error EthTransferFailed();

    error SwapFailed(address asset, uint256 amount);

    error WrongRoute(address fromToken, address toToken);

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param _rndtPoolHelper Pool helper address used for RDNT-WETH swaps
     * @param _uniRouter UniV2 router address used for all non RDNT-WETH swaps
     * @param _lendingPool Lending pool
     * @param _weth weth address
     * @param _rdntAddr RDNT token address
     * @param _ethLPRatio ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
     * @param _aaveOracle Aave oracle address
     */
    function initialize(
        IPoolHelper _rndtPoolHelper,
        address _uniRouter,
        ILendingPool _lendingPool,
        IWETH9 _weth,
        address _rdntAddr,
        uint256 _ethLPRatio,
        IAaveOracle _aaveOracle
    ) external initializer {
        if (address(_rndtPoolHelper) == address(0)) revert AddressZero();
        if (address(_uniRouter) == address(0)) revert AddressZero();
        if (address(_lendingPool) == address(0)) revert AddressZero();
        if (address(_weth) == address(0)) revert AddressZero();
        if (_rdntAddr == address(0)) revert AddressZero();
        if (_ethLPRatio == 0 || _ethLPRatio >= RATIO_DIVISOR) {
            revert InvalidRatio();
        }
        if (address(_aaveOracle) == address(0)) revert AddressZero();

        __Ownable_init(_msgSender());
        __Pausable_init();

        lendingPool = _lendingPool;
        poolHelper = _rndtPoolHelper;
        uniRouter = _uniRouter;
        weth = _weth;
        rdntAddr = _rdntAddr;
        ethLPRatio = _ethLPRatio;
        aaveOracle = _aaveOracle;
    }

    receive() external payable {}

    /**
     * @notice Set Price Provider.
     * @param _provider Price provider contract address.
     */
    function setPriceProvider(address _provider) external onlyOwner {
        if (_provider == address(0)) revert AddressZero();
        priceProvider = IPriceProvider(_provider);
        emit PriceProviderUpdated(_provider);
    }

    /**
     * @notice Set AAVE Oracle used to fetch asset prices in USD.
     * @param _aaveOracle oracle contract address.
     */
    function setAaveOracle(address _aaveOracle) external onlyOwner {
        if (_aaveOracle == address(0)) revert AddressZero();
        aaveOracle = IAaveOracle(_aaveOracle);
    }

    /**
     * @notice Set Multi fee distribution contract.
     * @param _mfdAddr New contract address.
     */
    function setMfd(address _mfdAddr) external onlyOwner {
        if (_mfdAddr == address(0)) revert AddressZero();
        mfd = IMultiFeeDistribution(_mfdAddr);
        emit MfdUpdated(_mfdAddr);
    }

    /**
     * @notice Set the ratio of ETH in the LP token
     * @dev The ratio typically doesn't change, but this function is provided for flexibility
     * when using with UniswapV3 in where the ratio can be different.
     * @param _ethLPRatio ratio of ETH in the LP token, (example: can be 2000 for an 80/20 lp)
     */
    function setEthLPRatio(uint256 _ethLPRatio) external onlyOwner {
        if (_ethLPRatio == 0 || _ethLPRatio >= RATIO_DIVISOR) {
            revert InvalidRatio();
        }
        ethLPRatio = _ethLPRatio;
        emit EthLPRatioUpdated(_ethLPRatio);
    }

    /**
     * @notice Set Pool Helper contract used fror WETH-RDNT swaps
     * @param _poolHelper New PoolHelper contract address.
     */
    function setPoolHelper(address _poolHelper) external onlyOwner {
        if (_poolHelper == address(0)) revert AddressZero();
        poolHelper = IPoolHelper(_poolHelper);
        emit PoolHelperUpdated(_poolHelper);
    }

    /**
     * @notice Set swap router
     * @param _uniRouter Address of swap router
     */
    function setUniRouter(address _uniRouter) external onlyOwner {
        if (_uniRouter == address(0)) revert AddressZero();
        uniRouter = _uniRouter;
        emit UniRouterUpdated(_uniRouter);
    }

    /**
     * @notice Set UniswapV3 Quoter
     * @param _uniV3Quoter address of the UniswapV3 Quoter
     * @dev Suggest to use static quoter by eden network on production
     * https://github.com/eden-network/uniswap-v3-static-quoter
     */
    function setUniV3Quoter(address _uniV3Quoter) external onlyOwner {
        if (_uniV3Quoter == address(0)) revert AddressZero();
        uniV3Quoter = IQuoter(_uniV3Quoter);
        emit UniV3QuoterUpdated(_uniV3Quoter);
    }

    /**
     * @notice Set UniswapV3 swap routes
     * @param _tokenIn Token to swap
     * @param _tokenOut Token to receive
     * @param _route Swap route for token
     */
    function setUniV3Route(address _tokenIn, address _tokenOut, bytes memory _route) external onlyOwner {
        if (_tokenIn == address(0) || _tokenOut == address(0)) {
            revert AddressZero();
        }
        // 43 is the minimum length of a UniswapV3 route with encodePacked.
        // (20 bytes) _tokenIn + (3 bytes) poolFee as uint24 + (20 bytes) _tokenOut
        uint256 routeLength = _route.length;
        if (routeLength < MIN_UNIV3_ROUTE_LENGTH && (routeLength - _ADDR_SIZE) % UNIV3_NEXT_OFFSET != 0) {
            revert WrongRoute(_tokenIn, _tokenOut);
        }
        _uniV3Route[_tokenIn][_tokenOut] = _route;
        emit RoutesUniV3Updated(_tokenIn, _tokenOut, _route);
    }

    /**
     * @notice Returns the stored swap route for UniswapV2 for the given tokens
     */
    function getUniV3Route(address _tokenIn, address _tokenOut) external view returns (bytes memory) {
        return _uniV3Route[_tokenIn][_tokenOut];
    }

    /**
     * @notice Returns pool helper address used for RDNT-WETH swaps
     */
    function getPoolHelper() external view returns (address) {
        return address(poolHelper);
    }

    /**
     * @notice Returns uni router address used for all non RDNT-WETH swaps
     */
    function getUniRouter() external view returns (address) {
        return uniRouter;
    }

    /**
     * @notice Get Variable debt token address
     * @param _asset underlying.
     */
    function getVDebtToken(address _asset) external view returns (address) {
        DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(_asset);
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @notice Calculate amount of specified `token` to be paired with amount of `_rdntIn`.
     * DO NOT CALL THIS FUNCTION FROM AN EXTERNAL CONTRACT; REFER TO THE FOLLOWING LINK FOR MORE INFORMATION:
     * https://github.com/Uniswap/v3-periphery/blob/464a8a49611272f7349c970e0fadb7ec1d3c1086/contracts/lens/Quoter.sol#L18
     * @dev this function is mainly used to calculate how much of the specified token is needed to match the provided RDNT amount
     *      when providing liquidity to an AMM.
     * @param _token address of the token that would be received
     * @param _rdntIn of RDNT to be sold
     * @return amount of _token received
     */
    function quoteFromToken(address _token, uint256 _rdntIn) public returns (uint256) {
        address weth_ = address(weth);
        if (_token != weth_) {
            uint256 wethAmount = poolHelper.quoteFromToken(_rdntIn);
            return _quoteUniswap(_token, weth_, wethAmount);
        }
        return poolHelper.quoteFromToken(_rdntIn);
    }

    /**
     * @notice Zap tokens to stake LP
     * @param _borrow option to borrow ETH
     * @param _asset to be used for zapping
     * @param _assetAmt amount of weth.
     * @param _rdntAmt amount of RDNT.
     * @param _lockTypeIndex lock length index.
     * @param _slippage maximum amount of slippage allowed for any occurring trades
     * @return LP amount
     */
    function zap(
        bool _borrow,
        address _asset,
        uint256 _assetAmt,
        uint256 _rdntAmt,
        uint256 _lockTypeIndex,
        uint256 _slippage
    ) public payable whenNotPaused returns (uint256) {
        return _zap(_borrow, _asset, _assetAmt, _rdntAmt, msg.sender, msg.sender, _lockTypeIndex, msg.sender, _slippage);
    }

    /**
     * @notice Zap tokens to stake LP
     * @dev It will use default lock index
     * @param _borrow option to borrow ETH
     * @param _asset to be used for zapping
     * @param _assetAmt amount of weth.
     * @param _rdntAmt amount of RDNT.
     * @param _onBehalf user address to be zapped.
     * @param _slippage maximum amount of slippage allowed for any occurring trades
     * @return LP amount
     */
    function zapOnBehalf(
        bool _borrow,
        address _asset,
        uint256 _assetAmt,
        uint256 _rdntAmt,
        address _onBehalf,
        uint256 _slippage
    ) public payable whenNotPaused returns (uint256) {
        uint256 duration = mfd.getDefaultLockIndex(_onBehalf);
        return _zap(_borrow, _asset, _assetAmt, _rdntAmt, msg.sender, _onBehalf, duration, _onBehalf, _slippage);
    }

    /**
     * @notice Calculates slippage ratio from usd value to LP
     * @param _assetValueUsd amount value in USD used to create LP pair
     * @param _liquidity LP token amount
     */
    function _calcSlippage(uint256 _assetValueUsd, uint256 _liquidity) internal returns (uint256 ratio) {
        priceProvider.update();
        uint256 lpAmountValueUsd = (_liquidity * priceProvider.getLpTokenPriceUsd()) / 1e18;
        ratio = (lpAmountValueUsd * (RATIO_DIVISOR)) / (_assetValueUsd);
    }

    /**
     * @notice Zap into LP
     * @param _borrow option to borrow ETH
     * @param _asset that will be used to zap.
     * @param _assetAmt amount of assets to be zapped
     * @param _rdntAmt amount of RDNT.
     * @param _from src address of RDNT
     * @param _onBehalf of the user.
     * @param _lockTypeIndex lock length index.
     * @param _refundAddress dust is refunded to this address.
     * @param _slippage maximum amount of slippage allowed for any occurring trades
     * @return liquidity LP amount
     */
    function _zap(
        bool _borrow,
        address _asset,
        uint256 _assetAmt,
        uint256 _rdntAmt,
        address _from,
        address _onBehalf,
        uint256 _lockTypeIndex,
        address _refundAddress,
        uint256 _slippage
    ) internal returns (uint256 liquidity) {
        IWETH9 weth_ = weth;
        if (_asset == address(0)) {
            _asset = address(weth_);
        }
        if (_slippage == 0) {
            _slippage = MAX_SLIPPAGE;
        } else {
            if (MAX_SLIPPAGE > _slippage || _slippage > RATIO_DIVISOR) {
                revert SpecifiedSlippageExceedLimit();
            }
        }
        bool isAssetWeth = _asset == address(weth_);

        // Handle pure ETH
        if (msg.value > 0) {
            if (!isAssetWeth) revert ReceivedETHOnAlternativeAssetZap();
            if (_borrow) revert InvalidZapETHSource();
            _assetAmt = msg.value;
            weth_.deposit{value: _assetAmt}();
        }
        if (_assetAmt == 0) revert AmountZero();
        uint256 assetAmountValueUsd =
            (_assetAmt * aaveOracle.getAssetPrice(_asset)) / (10 ** IERC20Metadata(_asset).decimals());

        // Handle borrowing logic
        if (_borrow) {
            // Borrow the asset on the users behalf
            lendingPool.borrow(_asset, _assetAmt, VARIABLE_INTEREST_RATE_MODE, REFERRAL_CODE, msg.sender);

            // If asset isn't WETH, swap for WETH
            if (!isAssetWeth) {
                _assetAmt = _safeSwap(_asset, address(weth_), _assetAmt, 0);
            }
        } else if (msg.value == 0) {
            // Transfer asset from user
            IERC20(_asset).safeTransferFrom(msg.sender, address(this), _assetAmt);
            if (!isAssetWeth) {
                _assetAmt = _safeSwap(_asset, address(weth_), _assetAmt, 0);
            }
        }

        weth_.approve(address(poolHelper), _assetAmt);
        //case where rdnt is matched with provided ETH
        if (_rdntAmt != 0) {
            if (_assetAmt < poolHelper.quoteFromToken(_rdntAmt)) {
                revert InsufficientETH();
            }
            // _from == this when zapping from vesting
            if (_from != address(this)) {
                IERC20(rdntAddr).safeTransferFrom(msg.sender, address(this), _rdntAmt);
            }

            IERC20(rdntAddr).forceApprove(address(poolHelper), _rdntAmt);
            liquidity = poolHelper.zapTokens(_assetAmt, _rdntAmt);
            assetAmountValueUsd = (assetAmountValueUsd * RATIO_DIVISOR) / ethLPRatio;
        } else {
            liquidity = poolHelper.zapWETH(_assetAmt);
        }

        if (address(priceProvider) != address(0)) {
            if (_calcSlippage(assetAmountValueUsd, liquidity) < _slippage) {
                revert SlippageTooHigh();
            }
        }

        IERC20(poolHelper.lpTokenAddr()).forceApprove(address(mfd), liquidity);
        mfd.stake(liquidity, _onBehalf, _lockTypeIndex);
        emit Zapped(_borrow, _assetAmt, _rdntAmt, _from, _onBehalf, _lockTypeIndex);

        _refundDust(rdntAddr, _asset, _refundAddress);
    }

    /**
     * @notice Pause zapping operation.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause zapping operation.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Allows owner to recover ETH locked in this contract.
     * @param to ETH receiver
     * @param value ETH amount
     */
    function withdrawLockedETH(address to, uint256 value) external onlyOwner {
        TransferHelper.safeTransferETH(to, value);
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
        IERC20(_tokenIn).forceApprove(uniRouter, _amountIn);
        bytes memory route = _uniV3Route[_tokenIn][_tokenOut];
        try ISwapRouter(uniRouter).exactInput(
            ISwapRouter.ExactInputParams({
                path: route,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: _amountOutMin
            })
        ) returns (uint256 amountOut) {
            return amountOut;
        } catch {
            revert SwapFailed(_tokenIn, _amountIn);
        }
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
        // NOTE!: For `quoteExactOutput` the path must be provided in reverse order:
        // i.e. _tokenOut -> _tokenIn
        return uniV3Quoter.quoteExactOutput(_uniV3Route[_tokenOut][_tokenIn], _amountOut);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
