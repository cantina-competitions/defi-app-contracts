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
    error StakeHelper_notEnoughLpTokensReceived();
    error StakeHelper_insufficientWeth9();
    error StakeHelper_safeTransferETHFailed();

    function stakeClaimedLogic(
        DefiAppHomeCenterStorage storage $,
        address caller,
        uint256 claimed,
        StakingParams memory staking
    ) public {
        IERC20 weth9 = IERC20(IDefiAppPoolHelper($.poolHelper).weth9());
        // Handle msg.value cases
        if (msg.value == 0) {
            weth9.safeTransferFrom(caller, address(this), staking.weth9ToStake);
        } else if (msg.value == staking.weth9ToStake) {
            _wrapWETH9(address(weth9), msg.value);
        } else {
            revert StakeHelper_msgValueMismatch();
        }

        // Zap the claimed tokens paired with the WETH9 into the pool
        weth9.approve($.poolHelper, staking.weth9ToStake);
        IERC20($.homeToken).approve($.poolHelper, claimed);
        uint256 received = IPoolHelper($.poolHelper).zapTokens(claimed, staking.weth9ToStake);
        IERC20 lpToken = IERC20(IDefiAppPoolHelper($.poolHelper).lpTokenAddr());

        // Check for bad slippage or manipulation
        _checkLpTokensReceived(lpToken, received, staking.minLpTokens);

        // Stake the LP tokens
        lpToken.forceApprove($.stakingAddress, received);
        MFDBase($.stakingAddress).stake(received, caller, staking.typeIndex);
    }

    function _checkLpTokensReceived(IERC20 lpToken, uint256 received, uint256 expected) private view {
        uint256 readLpTokenBal = lpToken.balanceOf(address(this));
        require(readLpTokenBal >= received && received >= expected, StakeHelper_notEnoughLpTokensReceived());
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
