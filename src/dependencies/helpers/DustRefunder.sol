// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Dust Refunder Contract Contract
/// @dev Refunds dust tokens
/// @author security@defi.app
contract DustRefunder {
    using SafeERC20 for IERC20;

    /**
     * @notice Refunds dust from a reference `prevBalance` to a `_refundAddress`
     * @param token The address of the token to refund
     * @param prevBalance The previous balance of the token before the operation
     * @param refundAddress The address to send the dust to
     */
    function _refundDust(address token, uint256 prevBalance, address refundAddress) internal {
        uint256 readAmt = IERC20(token).balanceOf(address(this));
        if (readAmt > prevBalance) {
            uint256 dustAmt = readAmt - prevBalance;
            IERC20(token).safeTransfer(refundAddress, dustAmt);
        }
    }
}
