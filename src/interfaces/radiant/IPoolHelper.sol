// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoolHelper {
    /// View Functions

    /// @notice Returns the address of the LP token
    function lpTokenAddr() external view returns (address);

    /// @notice Returns the reserve amounts of the pool
    function getReserves()
        external
        view
        returns (uint256 pairTokenReserve, uint256 weth9Reserve, uint256 lpTokenSupply);

    /// @notice Returns the price of LP token in WETH9
    /// @param _pairTokenPriceInWeth9 The price of the pair token in WETH9
    function getLpPrice(uint256 _pairTokenPriceInWeth9) external view returns (uint256 lpPriceInWeth9);

    /// @notice Returns a quote of `pairTokenAmount` in weth9 amount
    function quoteFromToken(uint256 pairTokenAmount) external view returns (uint256 weth9Amount);

    /// @notice Returns amount of weth9 required to for adding `lpAmount` of lpTokens.
    function quoteWETH(uint256 lpAmount) external view returns (uint256 weth9Amount);

    /// Core Functions

    /// @notice Zaps WETH9 amount into the pool, if weth9 is not the token0 or token1, it will swap it first
    function zapWETH(uint256 amount) external returns (uint256 lpTokens);

    /// @notice Zaps any amount of pairToken and weth9 into the pool
    function zapTokens(uint256 pairTokenAmount, uint256 weth9TokenAmount) external returns (uint256 lpTokens);
}
