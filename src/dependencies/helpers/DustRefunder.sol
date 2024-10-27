// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "../../interfaces/IWETH9.sol";

/// @title Dust Refunder Contract
/// @dev Refunds dust tokens remaining from zapping.
/// @author Radiant
contract DustRefunder {
    using SafeERC20 for IERC20;

    /**
     * @notice Refunds RDNT and WETH.
     * @param _rdnt RDNT address
     * @param _weth9 WETH9 address
     * @param _refundAddress Address for refund
     */
    function _refundDust(address _rdnt, address _weth9, address _refundAddress) internal {
        IERC20 rdnt = IERC20(_rdnt);
        IWETH9 weth9 = IWETH9(_weth9);

        uint256 dustWETH = weth9.balanceOf(address(this));
        if (dustWETH > 0) {
            weth9.transfer(_refundAddress, dustWETH);
        }
        uint256 dustRdnt = rdnt.balanceOf(address(this));
        if (dustRdnt > 0) {
            rdnt.safeTransfer(_refundAddress, dustRdnt);
        }
    }
}
