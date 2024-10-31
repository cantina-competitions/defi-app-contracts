// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DefiAppHomeCenterStorage, StakingParams} from "./DefiAppDataTypes.sol";
import {MFDBase} from "../dependencies/MultiFeeDistribution/MFDBase.sol";
import {IDefiAppPoolHelper, IPoolHelper} from "../interfaces/IDefiAppPoolHelper.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";

library StakeHelper {
    using SafeERC20 for IERC20;

    /// Custom Errors
    error StakeHelper_msgValueMismatch();
    error StakeHelper_insufficientWeth9();
    error StakeHelper_safeTransferETHFailed();

    function stakeClaimedLogic(DefiAppHomeCenterStorage storage $, uint256 claimed, StakingParams memory params)
        public
    {
        // Handle msg.value cases
        if (msg.value == 0) {
            IERC20(IDefiAppPoolHelper($.poolHelper).weth9()).safeTransferFrom(
                msg.sender, address(this), params.weth9ToStake
            );
        } else if (msg.value == params.weth9ToStake) {
            _wrapWETH9(IDefiAppPoolHelper($.poolHelper).weth9(), msg.value);
        } else {
            revert StakeHelper_msgValueMismatch();
        }

        IPoolHelper($.poolHelper).zapTokens(claimed, params.weth9ToStake);
    }

    function _wrapWETH9(address weth9, uint256 amount) private {
        IWETH9(weth9).deposit{value: amount}();
    }

    function _unwrapWETH9(address weth9, uint256 amount, address recipient) private {
        uint256 balanceWETH9 = IWETH9(weth9).balanceOf(address(this));
        require(balanceWETH9 >= amount, StakeHelper_insufficientWeth9());

        if (balanceWETH9 > 0) {
            IWETH9(weth9).withdraw(amount);
            _safeTransferETH(recipient, amount);
        }
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, StakeHelper_safeTransferETHFailed());
    }
}
