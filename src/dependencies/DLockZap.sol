// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DustRefunder} from "./helpers/DustRefunder.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UAccessControl} from "./UAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IMultiFeeDistribution} from "../interfaces/staker/IMultiFeeDistribution.sol";
import {IPoolHelper} from "../interfaces/staker/IPoolHelper.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {TransferHelper} from "./helpers/TransferHelper.sol";

/// @title DLockZap contract
/// @author security@defi.app
contract DLockZap is Initializable, UAccessControl, PausableUpgradeable, DustRefunder, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    struct ZapParams {
        uint256 weth9Amount;
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
    }

    /// Events
    event Zapped(
        uint256 _weth9Amt,
        uint256 _emissionTokenAmt,
        address indexed _from,
        address indexed _onBehalf,
        uint256 _lockTypeIndex
    );
    event MfdUpdated(address indexed mfdAddr);
    event PoolHelperUpdated(address indexed poolHelper);
    event RoutesUniV3Updated(address indexed tokenIn, address indexed tokenOut, bytes route);
    event LendingPoolApproveSet(address indexed lendingPool, bool isApproved);

    /// Custom Errors
    error DLockZap_addressZero();
    error DLockZap_amountZero();
    error DLoclZap_noChange();
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
     */
    function initialize(address emissionToken_, IWETH9 weth9_, address mfd_, IPoolHelper poolHelper_)
        external
        initializer
    {
        if (emissionToken_ == address(0)) revert DLockZap_addressZero();
        if (address(weth9_) == address(0)) revert DLockZap_addressZero();
        if (address(mfd_) == address(0)) revert DLockZap_addressZero();
        if (address(poolHelper_) == address(0)) revert DLockZap_addressZero();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        DLockZapStorage storage $ = _getDLockZapStorage();

        $.emissionToken = emissionToken_;
        $.weth9 = weth9_;
        $.mfd = IMultiFeeDistribution(mfd_);
        $.poolHelper = poolHelper_;
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

    /// Setter Methods

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

    /// Core methods

    /**
     * @notice Zap WETH9 to stake LP
     * @param weth9Amount amount of weth.
     * @param emissionTokenAmt amount of emissionToken.
     * @param lockTypeIndex lock length index.
     * @param minLpTokens the minimum amount of LP tokens to receive
     * @return LP amount
     */
    function zap(uint256 weth9Amount, uint256 emissionTokenAmt, uint256 lockTypeIndex, uint256 minLpTokens)
        public
        payable
        whenNotPaused
        returns (uint256)
    {
        ZapParams memory params = ZapParams({
            weth9Amount: weth9Amount,
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
     * @notice Zap WETH9 onbehalf a user to stake LP
     * @dev It will use default lock index for the user.
     * @param weth9Amount amount of weth9.
     * @param emissionTokenAmt optional amount of emissionToken to be paired with WETH9.
     * @param onBehalf user address to be zapped.
     * @param minLpTokens the minimum amount of LP tokens to receive
     * @return LP amount
     */
    function zapOnBehalf(uint256 weth9Amount, uint256 emissionTokenAmt, address onBehalf, uint256 minLpTokens)
        public
        payable
        whenNotPaused
        returns (uint256)
    {
        uint256 duration = _getDLockZapStorage().mfd.getDefaultLockIndex(onBehalf);
        ZapParams memory params = ZapParams({
            weth9Amount: weth9Amount,
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
        if (params.minLpTokens == 0) {
            revert DLockZap_unprotectedZap();
        }

        // Handle pure ETH
        if (msg.value > 0) {
            params.weth9Amount = msg.value;
            weth9_.deposit{value: params.weth9Amount}();
        }
        if (params.weth9Amount == 0) revert DLockZap_amountZero();

        // Handle borrowing logic
        if (msg.value == 0) {
            // Transfer asset from user
            IERC20(weth9_).safeTransferFrom(msg.sender, address(this), params.weth9Amount);
        }

        weth9_.approve(address($.poolHelper), params.weth9Amount);

        // Handle case where emissionToken is matched with provided WETH9
        if (params.emissionTokenAmt != 0) {
            if (params.weth9Amount < $.poolHelper.quoteFromToken(params.emissionTokenAmt)) {
                revert DLockZap_insufficientETH();
            }
            // _from == this when zapping from vesting
            if (params.from != address(this)) {
                IERC20($.emissionToken).safeTransferFrom(msg.sender, address(this), params.emissionTokenAmt);
            }

            IERC20($.emissionToken).forceApprove(address($.poolHelper), params.emissionTokenAmt);
            lpReceived = $.poolHelper.zapTokens(params.emissionTokenAmt, params.weth9Amount);
        } else {
            lpReceived = $.poolHelper.zapWETH(params.weth9Amount);
        }

        if (lpReceived < params.minLpTokens) revert DLockZap_slippageTooHigh();

        IERC20($.poolHelper.lpTokenAddr()).forceApprove(address($.mfd), lpReceived);
        $.mfd.stake(lpReceived, params.onBehalf, params.lockTypeIndex);
        emit Zapped(params.weth9Amount, params.emissionTokenAmt, params.from, params.onBehalf, params.lockTypeIndex);

        _refundDust($.emissionToken, params.refundAddress);
        _refundDust(address(weth9_), params.refundAddress);
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
