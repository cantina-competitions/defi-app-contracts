// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleRouter {
    enum OracleProviderType {
        Chainlink,
        Pyth
    }

    /**
     * @notice Get the underlying price of a kToken asset
     * @param asset to get the underlying price of
     * @return The underlying asset price
     *  Zero means the price is unavailable.
     */
    function getAssetPrice(address asset) external view returns (uint256);

    /// @notice Gets a list of prices from a list of assets addresses
    /// @param assets The list of assets addresses
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);

    /// @notice Gets the address of the source for an asset address
    /// @param asset The address of the asset
    /// @return address The address of the source, bytes32 The id of the source
    function getSourceOfAsset(address asset) external view returns (address, bytes32);

    /// @notice Set the source of an asset
    /// @param _asset The address of the asset
    /// @param _feedAddress The address of the feed
    /// @param _feedId The id of the feed
    /// @param _heartbeat The heartbeat of the feed
    /// @param _oracleType The type of the oracle
    /// @param isFallback True if the feed is a fallback
    function setAssetSource(
        address _asset,
        address _feedAddress,
        bytes32 _feedId,
        uint256 _heartbeat,
        OracleProviderType _oracleType,
        bool isFallback
    ) external;

    /**
     * @notice Updates multiple price feeds on Pyth oracle
     * @param priceUpdateData received from Pyth network and used to update the oracle
     */
    function updateUnderlyingPrices(bytes[] calldata priceUpdateData) external payable;
}
