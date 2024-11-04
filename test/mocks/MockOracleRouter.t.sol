// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IOracleRouter} from "../../src/interfaces/radiant/IOracleRouter.sol";

contract MockOracleRouter is IOracleRouter {
    mapping(address => uint256) internal _mockPrices;

    function mock_set_price(address asset, uint256 mockPriceIn18Decimals) external {
        _mockPrices[asset] = mockPriceIn18Decimals;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return _mockPrices[asset];
    }

    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        uint256 len = assets.length;
        uint256[] memory prices = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            prices[i] = _mockPrices[assets[i]];
        }
        return prices;
    }

    function getSourceOfAsset(address) external view returns (address, bytes32) {
        return (address(this), bytes32(0));
    }

    /// Mock: methods does nothing
    function setAssetSource(address, address, bytes32, uint256, IOracleRouter.OracleProviderType, bool) external {}

    /// Mock: methods does nothing
    function updateUnderlyingPrices(bytes[] calldata) external payable {}
}
