// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Dust Refunder Contract
/// @dev Refunds dust tokens
/// @author security@defi.app
contract DustRefunder {
    using SafeERC20 for IERC20;

    /**
     * @notice Refunds dust to  `_refundAddress`
     * @param token The address of the token to refund
     * @param refundAddress The address to send the dust to
     */
    function _refundDust(address token, address refundAddress) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(refundAddress, bal);
        }
    }
}
