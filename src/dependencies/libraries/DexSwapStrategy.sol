// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

struct SwapData {
    uint256 value; // amount of gas token that will be paid
    address addressToCall; // address to call and send bytes data to perform the aggregator swap
    address addressToApprove; // address to approve tokens that will be swapped
    bytes data; // bytes that will be passed to the aggregator to perform a swap
}

/// @title DexSwapStrategy
/// @author security@defi.app
library DexSwapStrategy {
    using SafeERC20 for IERC20;

    /// Custom Errors
    error DexSwapStrategy_nativeAssetsNotSupported();
    error DexSwapStrategy_swapperAddressNotApproved();
    error DexSwapStrategy_swapFailed();
    error DexSwapStrategy_receivedLessThanMinOutput();
    error DexSwapStrategy_invalidInputData();

    /**
     * @notice Swap function
     * @param data Data to perform the swap
     */
    function swap(
        address inputToken,
        uint256 amountIn,
        uint256 minOutput,
        bytes calldata data,
        function(address) view returns (bool) approvedSwapAddress
    ) internal {
        SwapData memory swapData = bytesToSwapData(data);

        if (swapData.value != 0) {
            revert DexSwapStrategy_nativeAssetsNotSupported();
        }

        if (!approvedSwapAddress(swapData.addressToCall)) {
            revert DexSwapStrategy_swapperAddressNotApproved();
        }

        IERC20(inputToken).forceApprove(swapData.addressToApprove, amountIn);

        uint256 returnAmount;
        (bool success, bytes memory responseData) = swapData.addressToCall.call(swapData.data);
        if (success) {
            returnAmount = abi.decode(responseData, (uint256));
        } else {
            revert DexSwapStrategy_swapFailed();
        }

        if (returnAmount < minOutput) {
            revert DexSwapStrategy_receivedLessThanMinOutput();
        }

        IERC20(inputToken).forceApprove(swapData.addressToApprove, 0);
    }

    /**
     * @notice Convert bytes to SwapData
     * @param rawData Raw data
     * @return swapData SwapData
     */
    function bytesToSwapData(bytes memory rawData) internal pure returns (SwapData memory) {
        if (rawData.length < 160) revert DexSwapStrategy_invalidInputData();

        SwapData memory swapData;
        uint256 value;
        address addressToCall;
        address addressToApprove;

        assembly {
            value := mload(add(rawData, 32))
            addressToCall := mload(add(rawData, 64))
            addressToApprove := mload(add(rawData, 96))
        }

        swapData.value = value;
        swapData.addressToCall = addressToCall;
        swapData.addressToApprove = addressToApprove;

        swapData.data = new bytes(rawData.length - 160);
        uint256 rawDataLength = rawData.length;
        for (uint256 i = 160; i < rawDataLength;) {
            swapData.data[i - 160] = rawData[i];
            unchecked {
                ++i;
            }
        }

        return swapData;
    }
}
