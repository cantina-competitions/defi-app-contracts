// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IPriceProvider} from "../interfaces/radiant/IPriceProvider.sol";
import {IBaseOracle} from "../interfaces/radiant/IBaseOracle.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UAccessControlUpgradeable} from "./UAccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPoolHelper} from "../interfaces/radiant/IPoolHelper.sol";
import {IChainlinkAdapter} from "../interfaces/radiant/IChainlinkAdapter.sol";

/// @title PriceProvider Contract
/// @author Radiant
contract PriceProvider is IPriceProvider, Initializable, UAccessControlUpgradeable, UUPSUpgradeable {
    /// Events
    event OracleUpdated(address indexed _newOracle);
    event PoolHelperUpdated(address indexed _poolHelper);
    event AggregatorUpdated(address indexed _baseTokenPriceInUsdProxyAggregator);
    event UsePoolUpdated(bool indexed _usePool);

    /// Custom Errors
    error AddressZero();
    error InvalidOracle();

    address public baseAssetChainlinkAdapter; // Chainlink aggregator for USD price of base token
    IPoolHelper public poolHelper;
    IBaseOracle public oracle;
    bool public usePool;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param _baseAssetChainlinkAdapter Chainlink aggregator for USD price of base token
     * @param _poolHelper Pool helper contract - Uniswap/Balancer
     */
    function initialize(IChainlinkAdapter _baseAssetChainlinkAdapter, IPoolHelper _poolHelper) public initializer {
        if (address(_baseAssetChainlinkAdapter) == (address(0))) revert AddressZero();
        if (address(_poolHelper) == (address(0))) revert AddressZero();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        poolHelper = _poolHelper;
        baseAssetChainlinkAdapter = address(_baseAssetChainlinkAdapter);
        usePool = true;
    }

    /**
     * @notice Update oracles.
     */
    function update() public {
        if (address(oracle) != address(0) && oracle.canUpdate()) {
            oracle.update();
        }
    }

    /**
     * @notice Returns the latest price in eth.
     */
    function getTokenPrice() public view returns (uint256 priceInEth) {
        if (usePool) {
            // use sparingly, TWAP/CL otherwise
            // priceInEth = poolHelper.getPrice(); TODO to implement on VolatileAMMPoolHelper
        } else {
            priceInEth = oracle.latestAnswerInEth();
        }
    }

    /**
     * @notice Returns the latest price in USD.
     */
    function getTokenPriceUsd() public view returns (uint256 price) {
        // use sparingly, TWAP/CL otherwise
        if (usePool) {
            uint256 ethPrice = IChainlinkAdapter(baseAssetChainlinkAdapter).latestAnswer();
            uint256 priceInEth = 1; //TODO to implement on VolatileAMMPoolHelper
            // uint256 priceInEth = poolHelper.getPrice();
            price = (priceInEth * uint256(ethPrice)) / (10 ** 8);
        } else {
            price = oracle.latestAnswer();
        }
    }

    /**
     * @notice Returns lp token price in ETH.
     */
    function getLpTokenPrice() public view returns (uint256) {
        // decis 8
        uint256 rdntPriceInEth = getTokenPrice();
        return poolHelper.getLpPrice(rdntPriceInEth);
    }

    /**
     * @notice Returns lp token price in USD.
     */
    function getLpTokenPriceUsd() public view returns (uint256 price) {
        // decimals 8
        uint256 lpPriceInEth = getLpTokenPrice();
        // decimals 8
        uint256 ethPrice = IChainlinkAdapter(baseAssetChainlinkAdapter).latestAnswer();
        price = (lpPriceInEth * uint256(ethPrice)) / (10 ** 8);
    }

    /**
     * @notice Returns lp token address.
     */
    function getLpTokenAddress() public view returns (address) {
        return poolHelper.lpTokenAddr();
    }

    /**
     * @notice Sets new oracle.
     */
    function setOracle(address _newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newOracle == address(0)) revert AddressZero();
        oracle = IBaseOracle(_newOracle);
        emit OracleUpdated(_newOracle);
    }

    /**
     * @notice Sets pool helper contract.
     */
    function setPoolHelper(address _poolHelper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        poolHelper = IPoolHelper(_poolHelper);
        if (getLpTokenPrice() == 0) revert InvalidOracle();
        emit PoolHelperUpdated(_poolHelper);
    }

    /**
     * @notice Sets base token price aggregator.
     */
    function setAggregator(address _baseAssetChainlinkAdapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseAssetChainlinkAdapter = _baseAssetChainlinkAdapter;
        if (getLpTokenPriceUsd() == 0) revert InvalidOracle();
        emit AggregatorUpdated(_baseAssetChainlinkAdapter);
    }

    /**
     * @notice Sets option to use pool.
     */
    function setUsePool(bool _usePool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usePool = _usePool;
        emit UsePoolUpdated(_usePool);
    }

    /**
     * @notice Returns decimals of price.
     */
    function decimals() public pure returns (uint256) {
        return 8;
    }

    function _authorizeUpgrade(address) internal view override onlyRole(UPGRADER_ROLE) {}
}
