// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVestingManager, VestParams, Vest} from "../interfaces/IVestingManager.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VestingManager Contract
/// @notice This contract manages the vesting of tokens for users
/// @dev This contract is used to create, manage and stop vesting of tokens for users
/// Based on: https://etherscan.deth.net/address/0x0689640d190b10765f09310fCfE9C670eDe4E25B#code
/// @author security@defi.app
contract VestingManager is IVestingManager, ERC721 {
    using SafeERC20 for IERC20;

    address public immutable vestingAsset;

    mapping(uint256 => Vest) public vests;

    uint256 public vestIds;

    uint256 public constant PERCENTAGE_PRECISION = 1e18;

    // custom errors
    error InvalidStart();
    error NotOwner();
    error NotVestReceiver();
    error InvalidStepSetting();
    error InvalidToken();
    error OnlyVestingTokenAllowed();
    error NoTokenURI();

    constructor(address vestAsset, string memory name, string memory symbol) ERC721(name, symbol) {
        require(vestAsset != address(0), InvalidToken());
        vestingAsset = vestAsset;
        vestIds = 1;
    }

    function tokenURI(uint256 vestId) public view override returns (string memory) {
        string memory uri = vests[vestId].tokenURI;
        if (bytes(uri).length > 0) {
            return uri;
        } else {
            revert NoTokenURI();
        }
    }

    function createVesting(VestParams calldata vestParams)
        external
        override
        returns (uint256 depositedShares, uint256 vestId, uint128 stepShares, uint128 cliffShares)
    {
        if (vestParams.start < block.timestamp) revert InvalidStart();
        if (vestParams.stepPercentage > PERCENTAGE_PRECISION) {
            revert InvalidStepSetting();
        }
        if (vestParams.stepDuration == 0 || vestParams.steps == 0) {
            revert InvalidStepSetting();
        }
        if (vestParams.token != vestParams.token) revert OnlyVestingTokenAllowed();

        depositedShares = _depositToken(address(vestParams.token), msg.sender, vestParams.amount);
        stepShares = uint128((vestParams.stepPercentage * depositedShares) / PERCENTAGE_PRECISION);
        cliffShares = uint128(depositedShares - (stepShares * vestParams.steps));

        vestId = vestIds++;
        _mint(vestParams.recipient, vestId);

        vests[vestId] = Vest({
            owner: msg.sender,
            token: IERC20(vestingAsset),
            start: vestParams.start,
            cliffDuration: vestParams.cliffDuration,
            stepDuration: vestParams.stepDuration,
            steps: vestParams.steps,
            cliffShares: cliffShares,
            stepShares: stepShares,
            claimed: 0,
            tokenURI: vestParams.tokenURI
        });

        emit CreateVesting(
            vestId,
            vestParams.token,
            msg.sender,
            vestParams.recipient,
            vestParams.start,
            vestParams.cliffDuration,
            vestParams.stepDuration,
            vestParams.steps,
            cliffShares,
            stepShares
        );
    }

    function withdraw(uint256 vestId) external override {
        Vest storage vest = vests[vestId];
        address recipient = ownerOf(vestId);
        if (recipient != msg.sender) revert NotVestReceiver();
        uint256 canClaim = _balanceOf(vest) - vest.claimed;

        if (canClaim == 0) return;

        vest.claimed += uint128(canClaim);

        _transferToken(address(vest.token), recipient, canClaim);

        emit Withdraw(vestId, vest.token, canClaim);
    }

    function stopVesting(uint256 vestId) external override {
        Vest memory vest = vests[vestId];

        if (vest.owner != msg.sender) revert NotOwner();

        uint256 amountVested = _balanceOf(vest);
        uint256 canClaim = amountVested - vest.claimed;
        uint256 returnShares = (vest.cliffShares + (vest.steps * vest.stepShares)) - amountVested;

        delete vests[vestId];

        _transferToken(address(vest.token), ownerOf(vestId), canClaim);
        _transferToken(address(vest.token), msg.sender, returnShares);

        emit CancelVesting(vestId, returnShares, canClaim, vest.token);
    }

    function vestBalance(uint256 vestId) external view override returns (uint256) {
        Vest memory vest = vests[vestId];
        return _balanceOf(vest) - vest.claimed;
    }

    function _balanceOf(Vest memory vest) internal view returns (uint256 claimable) {
        uint256 timeAfterCliff = vest.start + vest.cliffDuration;

        if (block.timestamp < timeAfterCliff) {
            return claimable;
        }

        uint256 passedSinceCliff = block.timestamp - timeAfterCliff;

        uint256 stepPassed = Math.min(vest.steps, passedSinceCliff / vest.stepDuration);

        claimable = vest.cliffShares + (vest.stepShares * stepPassed);
    }

    function updateOwner(uint256 vestId, address newOwner) external override {
        Vest storage vest = vests[vestId];
        if (vest.owner != msg.sender) revert NotOwner();
        vest.owner = newOwner;
        emit LogUpdateOwner(vestId, newOwner);
    }

    function _depositToken(address token, address from, uint256 amount) internal returns (uint256 depositedShares) {
        IERC20(token).safeTransferFrom(from, address(this), amount);
        depositedShares = amount;
    }

    function _transferToken(address token, address to, uint256 shares) internal {
        IERC20(token).safeTransfer(to, shares);
    }
}
