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
import {IWETH9} from "../interfaces/IWETH9.sol";
import {TransferHelper} from "./helpers/TransferHelper.sol";
import {IOracleRouter} from "../interfaces/radiant/IOracleRouter.sol";

/// @title DLockZap contract
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
        uint256 minLpTokens;
    }

    struct DLockZapStorage {
        address emissionToken;
        IWETH9 weth9;
        IMultiFeeDistribution mfd;
        IPoolHelper poolHelper;
        IOracleRouter oracleRouter;
        uint256 lpRatio;
        mapping(address => bool) approvedLendingPools;
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
    event MfdUpdated(address indexed mfdAddr);
    event PoolHelperUpdated(address indexed poolHelper);
    event lpRatioUpdated(uint256 lpRatio);
    event RoutesUniV3Updated(address indexed tokenIn, address indexed tokenOut, bytes route);
    event LendingPoolApproveSet(address indexed lendingPool, bool isApproved);
    event OracleRouterUpdated(address indexed oracleRouter);

    /// Custom Errors
    error DLockZap_addressZero();
    error DLockZap_amountZero();
    error DLockZap_invalidRatio();
    error DLoclZap_noChange();
    error DLockZap_invalidLendingPool();
    error DLockZap_unprotectedZap();
    error DLockZap_receivedETHOnAlternativeAssetZap();
    error DLockZap_invalidZapETHSource();
    error DLockZap_insufficientETH();
    error DLockZap_slippageTooHigh();
    error DLockZap_momentarilyTokenSwapNotSupported();

    uint256 public constant RATIO_DIVISOR = 10_000;
    uint256 public constant VARIABLE_INTEREST_RATE_MODE = 2;
    uint16 public constant REFERRAL_CODE = 0;

    /// State Variables
    bytes32 internal constant DLockZapStorageLocation =
    // cast keccak "DLockZapStorageLocation"
     0xcdbbeb0a1d627c97fab1e071a5c3c7ce887bb6507ffac02b10e2af57d4ae83e2;

    function _getDLockZapStorage() internal pure returns (DLockZapStorage storage $) {
        assembly {
            $.slot := DLockZapStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param emissionToken_ emissionToken token address
     * @param weth9_ weth9 address
     * @param mfd_ Multi fee distribution contract address
     * @param poolHelper_ Pool helper address used for emissionToken-WETH swaps
     * @param lpRatio_ ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
     * @param oracleRouter_ Oracle router address
     */
    function initialize(
        address emissionToken_,
        IWETH9 weth9_,
        address mfd_,
        IPoolHelper poolHelper_,
        uint256 lpRatio_,
        IOracleRouter oracleRouter_
    ) external initializer {
        if (emissionToken_ == address(0)) revert DLockZap_addressZero();
        if (address(weth9_) == address(0)) revert DLockZap_addressZero();
        if (address(mfd_) == address(0)) revert DLockZap_addressZero();
        if (address(poolHelper_) == address(0)) revert DLockZap_addressZero();
        if (lpRatio_ == 0 || lpRatio_ >= RATIO_DIVISOR) revert DLockZap_invalidRatio();
        if (address(oracleRouter_) == address(0)) revert DLockZap_addressZero();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        DLockZapStorage storage $ = _getDLockZapStorage();

        $.emissionToken = emissionToken_;
        $.weth9 = weth9_;
        $.mfd = IMultiFeeDistribution(mfd_);
        $.poolHelper = poolHelper_;
        $.lpRatio = lpRatio_;
        $.oracleRouter = oracleRouter_;
    }

    receive() external payable {}

    /// View Methods

    function emissionToken() public view returns (address) {
        return _getDLockZapStorage().emissionToken;
    }

    function weth9() public view returns (IWETH9) {
        return _getDLockZapStorage().weth9;
    }

    function mfd() public view returns (IMultiFeeDistribution) {
        return _getDLockZapStorage().mfd;
    }

    function poolHelper() public view returns (IPoolHelper) {
        return _getDLockZapStorage().poolHelper;
    }

    function lpRatio() public view returns (uint256) {
        return _getDLockZapStorage().lpRatio;
    }

    function oracleRouter() public view returns (IOracleRouter) {
        return _getDLockZapStorage().oracleRouter;
    }

    function isApprovedLendingPool(address lendingPool) public view returns (bool) {
        return _getDLockZapStorage().approvedLendingPools[lendingPool];
    }

    /**
     * @notice Get Variable debt token address
     * @param asset underlying
     * @param lendingPool to check
     */
    function getVDebtToken(address asset, ILendingPool lendingPool) external view returns (address) {
        DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(asset);
        return reserveData.variableDebtTokenAddress;
    }

    /**
     * @notice Calculate amount of specified `token` to be paired with amount of `_emissionTokenIn`.
     * DO NOT CALL THIS FUNCTION FROM AN EXTERNAL CONTRACT; REFER TO THE FOLLOWING LINK FOR MORE INFORMATION:
     * https://github.com/Uniswap/v3-periphery/blob/464a8a49611272f7349c970e0fadb7ec1d3c1086/contracts/lens/Quoter.sol#L18
     *
     * @param token address of the token that would be received
     * @param emissionTokenIn of emissionToken to be sold
     * @return amount of _token received
     *
     * @dev This function is mainly used to calculate how much of the specified token is needed to match the provided
     * emissionToken amount when providing lpReceived to an AMM.
     */
    function quoteFromToken(address token, uint256 emissionTokenIn) public view returns (uint256) {
        DLockZapStorage storage $ = _getDLockZapStorage();
        address weth9_ = address($.weth9);
        if (token != weth9_) {
            uint256 wethAmount = $.poolHelper.quoteFromToken(emissionTokenIn);
            return _quoteSwap(token, weth9_, wethAmount);
        }
        return $.poolHelper.quoteFromToken(emissionTokenIn);
    }

    /// Setter Methods

    /**
     * @notice Set the ratio of ETH in the LP token
     * @dev The ratio typically doesn't change, but this function is provided for flexibility
     * when using with UniswapV3 in where the ratio can be different.
     * @param lpRatio_ ratio of ETH in the LP token, (example: can be 2000 for an 80/20 lp)
     */
    function setlpRatio(uint256 lpRatio_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (lpRatio_ == 0 || lpRatio_ >= RATIO_DIVISOR) revert DLockZap_invalidRatio();
        _getDLockZapStorage().lpRatio = lpRatio_;
        emit lpRatioUpdated(lpRatio_);
    }

    /// @notice Set Oracle Router.
    /// @param oracleRouter_ Oracle router contract address.
    function setOracleRouter(address oracleRouter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracleRouter_ == address(0)) revert DLockZap_addressZero();
        _getDLockZapStorage().oracleRouter = IOracleRouter(oracleRouter_);
        emit OracleRouterUpdated(oracleRouter_);
    }

    /**
     * @notice Set Multi fee distribution contract.
     * @param mfdAddr_ New contract address.
     */
    function setMfd(address mfdAddr_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (mfdAddr_ == address(0)) revert DLockZap_addressZero();
        _getDLockZapStorage().mfd = IMultiFeeDistribution(mfdAddr_);
        emit MfdUpdated(mfdAddr_);
    }

    /**
     * @notice Set Pool Helper contract used fror WETH-emissionToken swaps
     * @param poolHelper_ New PoolHelper contract address.
     */
    function setPoolHelper(address poolHelper_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (poolHelper_ == address(0)) revert DLockZap_addressZero();
        _getDLockZapStorage().poolHelper = IPoolHelper(poolHelper_);
        emit PoolHelperUpdated(poolHelper_);
    }

    /**
     * @notice Set `_lendingPool` as an approved or not lending pool for borrow operation in zap.
     * @param lendingPool Address of lending pool to set
     * @param isApproved  true or false
     */
    function setLendingPool(address lendingPool, bool isApproved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (lendingPool == address(0)) revert DLockZap_addressZero();
        if (_getDLockZapStorage().approvedLendingPools[lendingPool] == isApproved) revert DLoclZap_noChange();
        _getDLockZapStorage().approvedLendingPools[lendingPool] = isApproved;
        emit LendingPoolApproveSet(lendingPool, isApproved);
    }

    /// Core methods

    /**
     * @notice Zap tokens to stake LP
     * @param borrow option to borrow ETH
     * @param lendingPool lending pool address to be used for zapping. Use only Riz lending pools
     * @param asset to be used for zapping
     * @param assetAmt amount of weth.
     * @param emissionTokenAmt amount of emissionToken.
     * @param lockTypeIndex lock length index.
     * @param minLpTokens the minimum amount of LP tokens to receive
     * @return LP amount
     */
    function zap(
        bool borrow,
        address lendingPool,
        address asset,
        uint256 assetAmt,
        uint256 emissionTokenAmt,
        uint256 lockTypeIndex,
        uint256 minLpTokens
    ) public payable whenNotPaused returns (uint256) {
        ZapParams memory params = ZapParams({
            borrow: borrow,
            lendingPool: lendingPool,
            asset: asset,
            assetAmt: assetAmt,
            emissionTokenAmt: emissionTokenAmt,
            from: msg.sender,
            onBehalf: msg.sender,
            lockTypeIndex: lockTypeIndex,
            refundAddress: msg.sender,
            minLpTokens: minLpTokens
        });
        return _zap(params);
    }

    /**
     * @notice Riz Zap tokens to stake LP
     * @dev It will use default lock index
     * @param borrow option to borrow ETH
     * @param lendingPool lending pool address to be used for zapping. Use only Riz lending pools
     * @param asset to be used for zapping
     * @param assetAmt amount of weth.
     * @param emissionTokenAmt amount of emissionToken.
     * @param onBehalf user address to be zapped.
     * @param minLpTokens the minimum amount of LP tokens to receive
     * @return LP amount
     */
    function zapOnBehalf(
        bool borrow,
        address lendingPool,
        address asset,
        uint256 assetAmt,
        uint256 emissionTokenAmt,
        address onBehalf,
        uint256 minLpTokens
    ) public payable whenNotPaused returns (uint256) {
        uint256 duration = _getDLockZapStorage().mfd.getDefaultLockIndex(onBehalf);
        ZapParams memory params = ZapParams({
            borrow: borrow,
            lendingPool: lendingPool,
            asset: asset,
            assetAmt: assetAmt,
            emissionTokenAmt: emissionTokenAmt,
            from: msg.sender,
            onBehalf: onBehalf,
            lockTypeIndex: duration,
            refundAddress: msg.sender,
            minLpTokens: minLpTokens
        });
        return _zap(params);
    }

    /// Internal methods

    /**
     * @notice Zap into LP
     * @param params ZapParams struct
     */
    function _zap(ZapParams memory params) internal returns (uint256 lpReceived) {
        DLockZapStorage storage $ = _getDLockZapStorage();
        IWETH9 weth9_ = $.weth9;
        if (params.asset == address(0)) {
            params.asset = address(weth9_);
        }
        if (params.minLpTokens == 0) {
            revert DLockZap_unprotectedZap();
        }
        bool isAssetWeth = params.asset == address(weth9_);

        // Handle pure ETH
        if (msg.value > 0) {
            if (!isAssetWeth) revert DLockZap_receivedETHOnAlternativeAssetZap();
            if (params.borrow) revert DLockZap_invalidZapETHSource();
            params.assetAmt = msg.value;
            weth9_.deposit{value: params.assetAmt}();
        }
        if (params.assetAmt == 0) revert DLockZap_amountZero();

        // Handle borrowing logic
        if (params.borrow) {
            if (!isApprovedLendingPool(params.lendingPool)) revert DLockZap_invalidLendingPool();
            // Borrow the asset on the users behalf
            ILendingPool(params.lendingPool).borrow(
                params.asset, params.assetAmt, VARIABLE_INTEREST_RATE_MODE, REFERRAL_CODE, msg.sender
            );

            // If asset isn't WETH, swap for WETH
            if (!isAssetWeth) {
                params.assetAmt = _safeSwap(params.asset, address(weth9_), params.assetAmt, 0);
            }
        } else if (msg.value == 0) {
            // Transfer asset from user
            IERC20(params.asset).safeTransferFrom(msg.sender, address(this), params.assetAmt);
            if (!isAssetWeth) {
                params.assetAmt = _safeSwap(params.asset, address(weth9_), params.assetAmt, 0);
            }
        }

        weth9_.approve(address($.poolHelper), params.assetAmt);
        //case where emissionToken is matched with provided ETH
        if (params.emissionTokenAmt != 0) {
            if (params.assetAmt < $.poolHelper.quoteFromToken(params.emissionTokenAmt)) {
                revert DLockZap_insufficientETH();
            }
            // _from == this when zapping from vesting
            if (params.from != address(this)) {
                IERC20($.emissionToken).safeTransferFrom(msg.sender, address(this), params.emissionTokenAmt);
            }

            IERC20($.emissionToken).forceApprove(address($.poolHelper), params.emissionTokenAmt);
            lpReceived = $.poolHelper.zapTokens(params.emissionTokenAmt, params.assetAmt);
        } else {
            lpReceived = $.poolHelper.zapWETH(params.assetAmt);
        }

        if (lpReceived < params.minLpTokens) revert DLockZap_slippageTooHigh();

        IERC20($.poolHelper.lpTokenAddr()).forceApprove(address($.mfd), lpReceived);
        $.mfd.stake(lpReceived, params.onBehalf, params.lockTypeIndex);
        emit Zapped(
            params.borrow, params.assetAmt, params.emissionTokenAmt, params.from, params.onBehalf, params.lockTypeIndex
        );

        _refundDust($.emissionToken, params.refundAddress);
        _refundDust(params.asset, params.refundAddress);
    }

    /**
     * @dev Internal function that handles general swaps and can be used safely in loops to throw if
     * an intermediate swap fails
     * @param tokenIn to be swapped
     * @param tokenOut to be received
     * @param amountIn to swap
     * @param amountOutMin expected
     */
    function _safeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        internal
        pure
        returns (uint256)
    {
        /// TODO: To be implemented as a future feature: to swap any token in order to `zap`
        tokenIn;
        tokenOut;
        amountIn;
        amountOutMin;
        revert DLockZap_momentarilyTokenSwapNotSupported();
    }

    /**
     * @dev Internal function to get `amountIn` from an exact output in UniswapV3.
     * @param tokenIn to be swapped
     * @param tokenOut to be received
     * @param amountOut expected to be received
     */
    function _quoteSwap(address tokenIn, address tokenOut, uint256 amountOut) internal pure returns (uint256) {
        // TODO Refer to `_safeSwap`,
        tokenIn;
        tokenOut;
        amountOut;
        revert DLockZap_momentarilyTokenSwapNotSupported();
    }

    /// Emergency methods

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

    /// Upgrade hook

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}
}
