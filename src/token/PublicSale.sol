// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PublicSale Contract
/// @notice Contract for the public sale of tokens.
/// @dev This contract allows users to deposit USDC and purchase tokens.
/// Based on: https://etherscan.io/address/0xcfd9cb8f15a9732bc449b05d97c29244de2259b2#code
/// @author security@defi.app
contract PublicSale is AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /**
     * @notice Info about user deposit
     */
    struct UserDepositInfo {
        uint256 amountDeposited; // Total amount deposited by the user
        uint256 purchasedTokens; // Total tokens purchased by the user
    }

    /**
     * @notice Struct for tier price and cap
     */
    struct Tier {
        uint256 price; // Price of the token
        uint256 cap; // Cap for the tier
        uint256 vesting; // Vesting time for the tier
    }

    struct SaleSchedule {
        uint256 start; // Public sale start timestamp
        uint256 end; // End timestamp
    }

    struct SaleParameters {
        uint256 minDepositAmount; // Minimum USD amount required per purchase.
        uint256 maxDepositAmount; // Maximum USD amount allowed per wallet.
    }

    enum Stages {
        Completed, // Sale is final
        ComingSoon, // Contract is deployed but not yet started
        TokenPurchase // Deposit and purchase tokens

    }

    event ExternalContractsSet(address indexed user, address treasury, IERC20 usdc);
    event TiersUpdate(address indexed user, Tier[3] tiers);
    event MaxTotalFundsUpdate(address indexed user, uint256 maxTotalFunds);
    event SaleParametersUpdate(address indexed user, uint256 minDepositAmount, uint256 maxDepositAmount);
    event SaleScheduleUpdate(address indexed user, uint256 comingSoon, uint256 tokenPurchase);
    event TokensPurchase(
        address indexed user, uint256 depositedAmount, uint256 purchasedTokens, uint256 totalFundsCollected
    );
    event SaleCompleted();
    event RecoverAsset(address asset, address withdrawTo, uint256 amount);

    /**
     * @dev Error thrown when a user is not verified.
     * @param _selector The function selector that triggered the error.
     * @param _user The address of the user that is not verified.
     */
    error UserNotVerified(bytes4 _selector, address _user);

    /**
     * @dev Error indicating that the purchase input is invalid.
     * @param _selector The function selector where the error occurred.
     * @param _input The invalid input that was provided.
     * @param _message A message providing additional details about the error.
     * @param _suggestedInput A suggested valid input to correct the error.
     */
    error InvalidPurchaseInputHandler(bytes4 _selector, bytes32 _input, bytes32 _message, uint256 _suggestedInput);
    error InvalidPurchaseInput(bytes4 _selector, bytes32 _input, bytes32 _message);

    /**
     * @dev Error thrown when an input is invalid.
     * @param _selector The function selector that triggered the error.
     * @param _input The invalid input provided.
     */
    error InvalidInput(bytes4 _selector, bytes32 _input);

    /**
     * @dev Error thrown when the contract is in the wrong stage.
     * @param _selector The function selector that triggered the error.
     * @param _currentStage The current stage of the contract.
     * @param _requiredStage The required stage for the operation.
     */
    error WrongStage(bytes4 _selector, Stages _currentStage, Stages _requiredStage);

    /**
     * @dev Admin Role: Manages contract parameters setup like sale configuration and recipient of funds
     */
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /**
     * @notice Maximum funds allowed to be collected.
     * @dev 20,000,000 USDC(*) times 10^6, 6 is the number of decimals of USDC.
     */
    uint256 public maxTotalFunds;

    /**
     * @dev Recipient of collected funds.
     */
    address private immutable treasury;

    /**
     * @dev Address of USDC token.
     */
    IERC20 private immutable USDC;

    /**
     * @dev Array of Tier structs representing different price tiers in Sale.
     */
    Tier[3] public tiers;
    uint256[3] public tiersDeposited;

    /**
     * @dev Sale stages timestamps.
     */
    SaleSchedule public saleSchedule;

    /**
     * @dev Sale constraints for each wallet.
     */
    SaleParameters public saleParameters;

    /// Tracking the sale

    /**
     * @dev Total amount of USD collected so far.
     */
    uint256 public totalFundsCollected;

    /**
     * @dev Mapping to track deposits by each user.
     */
    mapping(address => UserDepositInfo) public userDeposits;

    /**
     * @dev Modifier to ensure that the current stage matches the required stage for the function execution.
     * @param _requiredStage The exact stage required for the function to execute.
     * @notice The function will revert if the current stage is not identical to the required stage.
     */
    modifier atStage(Stages _requiredStage) {
        Stages _currentStage = _getCurrentStage();

        if (_currentStage != _requiredStage) {
            revert WrongStage(msg.sig, _currentStage, _requiredStage);
        }

        _;
    }

    constructor(address _superAdmin, address _admin, address _operator, address _treasury, IERC20 _usdc) {
        address ZERO_ADDRESS = address(0);

        require(
            (_superAdmin != ZERO_ADDRESS) && (_admin != ZERO_ADDRESS) && (_operator != ZERO_ADDRESS)
                && (_treasury != ZERO_ADDRESS) && (address(_usdc) != ZERO_ADDRESS)
        );

        _pause();

        treasury = _treasury;
        USDC = _usdc;
        emit ExternalContractsSet(msg.sender, treasury, USDC);

        // Tier prices are scaled by 10^18 to keep precision during division
        _setTiers(
            [
                Tier(120000000000000000, 2_000_000e6, 540 days), // 0
                Tier(160000000000000000, 4_000_000e6, 360 days), // 1
                Tier(180000000000000000, 8_000_000e6, 180 days) // 2
            ]
        );

        _grantRole(DEFAULT_ADMIN_ROLE, _superAdmin);
        _grantRole(ADMIN_ROLE, _admin);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the sale parameters including minimum and maximum deposit amounts.
     * @dev This function can only be called by an account with the ADMIN_ROLE and when the contract is paused.
     * @param _minDepositAmount The minimum amount that can be deposited.
     * @param _maxDepositAmount The maximum amount that can be deposited.
     * Emits a {SaleParametersUpdate} event.
     */
    function setSaleParameters(uint256 _minDepositAmount, uint256 _maxDepositAmount)
        external
        whenPaused
        onlyRole(ADMIN_ROLE)
    {
        require(_minDepositAmount < _maxDepositAmount);

        saleParameters = SaleParameters(_minDepositAmount, _maxDepositAmount);
        emit SaleParametersUpdate(msg.sender, _minDepositAmount, _maxDepositAmount);
    }

    /**
     * @notice Sets the sale schedule including KYC and token purchase periods.
     * @dev This function can only be called by an account with the ADMIN_ROLE and when the contract is paused.
     * @param _tokenPurchaseStart The timestamp until which users can start purchasing.
     * @param _tokenPurchaseEnd The timestamp until which token purchases can be made.
     * Emits a {SaleScheduleUpdate} event.
     */
    function setSaleSchedule(uint256 _tokenPurchaseStart, uint256 _tokenPurchaseEnd)
        external
        whenPaused
        onlyRole(ADMIN_ROLE)
    {
        require((_tokenPurchaseStart < _tokenPurchaseEnd));

        saleSchedule = SaleSchedule(_tokenPurchaseStart, _tokenPurchaseEnd);
        emit SaleScheduleUpdate(msg.sender, _tokenPurchaseStart, _tokenPurchaseEnd);
    }

    /**
     * @notice Sets the tiers for the sale.
     * @dev This function can only be called by an account with the ADMIN_ROLE and when the contract is paused.
     * @param _tiers An array of Tier structs representing the different tiers.
     * Emits a {TiersUpdate} event.
     */
    function setTiers(Tier[3] calldata _tiers) public atStage(Stages.ComingSoon) onlyRole(ADMIN_ROLE) {
        bytes32 tiersHash_ = keccak256(bytes.concat(msg.data[4:]));
        bytes32 zeroBytesHash_ = keccak256(bytes.concat(new bytes(256)));
        require(tiersHash_ != zeroBytesHash_);

        _setTiers(_tiers);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit using USDC and purchase tokens.
     * @param _amount Amount of USDC to deposit.
     * @param _tierIndex Tier index to purchase.
     * @dev Emits a Purchase event upon successful purchase.
     */
    function depositUSDC(uint256 _amount, uint256 _tierIndex) external whenNotPaused atStage(Stages.TokenPurchase) {
        UserDepositInfo storage userDepositInfo = userDeposits[msg.sender];

        _verifyDepositConditions(_amount, userDepositInfo.amountDeposited);
        _purchase(_amount, USDC, userDepositInfo, _tierIndex);
    }

    /**
     * @notice Recover assets from the contract.
     * @param recipient Address to send the assets to.
     * @param asset Address of the asset to withdraw (e.g., USDC).
     */
    function recoverAssets(address recipient, IERC20 asset) external onlyRole(ADMIN_ROLE) {
        uint256 contractBalance = asset.balanceOf(address(this));
        asset.safeTransfer(recipient, contractBalance);
        emit RecoverAsset(address(asset), recipient, contractBalance);
    }

    /**
     * @notice Pause the contract, preventing deposits.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract, allowing deposits.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle the purchase logic.
     * @param _amountUSD Amount to deposit.
     * @param _asset Asset to deposit (USDC).
     * @param _userDepositInfo User deposit info.
     * @param _tierIndex Tier index to purchase.
     * @dev Emits a Purchase event upon successful purchase.
     */
    function _purchase(uint256 _amountUSD, IERC20 _asset, UserDepositInfo storage _userDepositInfo, uint256 _tierIndex)
        private
    {
        (uint256 _purchasedTokens, uint256 _remainingAmount) =
            _calculateTokensToTransfer(_amountUSD, _tierIndex, tiers, tiersDeposited);

        uint256 depositedAmount_ = _amountUSD - _remainingAmount;

        totalFundsCollected += depositedAmount_;
        tiersDeposited[_tierIndex] += depositedAmount_;

        _userDepositInfo.amountDeposited += depositedAmount_;
        _userDepositInfo.purchasedTokens += _purchasedTokens;

        _asset.safeTransferFrom(msg.sender, treasury, depositedAmount_);
        _setVestingHook(msg.sender, _purchasedTokens, tiers[_tierIndex].vesting);
        emit TokensPurchase(msg.sender, depositedAmount_, _purchasedTokens, totalFundsCollected);

        if (_getRemainingCap() == 0) {
            _pause();
            emit SaleCompleted();
        }
    }

    /**
     * @notice Internal function to verify deposit conditions like minimum/maximum amount and whitelist.
     * @param _amount Amount to deposit.
     * @param _amountDeposited Amount already deposited by the user.
     * @dev Throws custom errors if any condition fails.
     */
    function _verifyDepositConditions(uint256 _amount, uint256 _amountDeposited) private view {
        if (_amount < 10e6) {
            revert InvalidPurchaseInputHandler(msg.sig, bytes32("_amount"), bytes32("at least"), 10e6);
        }

        SaleParameters memory _saleParameters = saleParameters;

        if ((_amount + _amountDeposited) < _saleParameters.minDepositAmount) {
            revert InvalidPurchaseInputHandler(
                msg.sig, bytes32("_amount"), bytes32("below minDepositAmount"), _saleParameters.minDepositAmount
            );
        }

        uint256 _remainingAmount = _saleParameters.maxDepositAmount - _amountDeposited;
        if (_amount > _remainingAmount) {
            revert InvalidPurchaseInputHandler(
                msg.sig, bytes32("_amount"), bytes32("exceeds maxDepositAmount"), _remainingAmount
            );
        }
    }

    /**
     * @notice Internal function to set the tiers.
     * @param _tiers An array of Tier structs representing the different tiers.
     * @dev Emits a {TiersUpdate} event if the new tiers are set.
     */
    function _setTiers(Tier[3] memory _tiers) private {
        for (uint256 i = 0; i < 4; i++) {
            tiers[i] = _tiers[i];
            maxTotalFunds += _tiers[i].cap;
        }

        emit TiersUpdate(msg.sender, _tiers);
        emit MaxTotalFundsUpdate(msg.sender, maxTotalFunds);
    }

    /**
     * @notice Calculates the number of tokens to transfer based on the deposited amount and tiers.
     * @dev This function accounts for multiple tiers and computes tokens across them if necessary.
     * @param _amount The amount deposited by the user.
     * @param _tierIndex The index tier to purchase.
     * @param _tiers An array containing the details of each tier.
     * @return A tuple containing:
     *         - `resultingTokens_` The total number of tokens purchased.
     *         - `remainingAmount_` The remaining amount after token computation.
     */
    function _calculateTokensToTransfer(
        uint256 _amount,
        uint256 _tierIndex,
        Tier[3] memory _tiers,
        uint256[3] memory _tiersDeposited
    ) private pure returns (uint256, uint256) {
        Tier memory _tier = _tiers[_tierIndex];
        uint256 _remainingTierCap = _tier.cap - _tiersDeposited[_tierIndex];

        if (_remainingTierCap == 0) {
            revert InvalidPurchaseInput(this.depositUSDC.selector, "_tierIndex", "tier cap reached");
        }

        // If amount is within the current tier cap we don't need to split the price into multiple tiers
        if (_amount <= _remainingTierCap) {
            return (_computeTokens(_amount, _tier.price), 0);
        } else {
            uint256 _remainingAmount = _amount - _remainingTierCap;
            return (_computeTokens(_remainingTierCap, _tier.price), _remainingAmount);
        }
    }

    /**
     * @param _amount The amount in USD
     * @param _price The price of the token in USD
     */
    function _computeTokens(uint256 _amount, uint256 _price) private pure returns (uint256) {
        // _price = price * 10^18 --> precision scaling
        // _amount = (input_amount * 10^6 (USDC/T)) * 10^18 (_price)
        // (_amount * 1e18) / _price = (10^6 * 10^18) / 10^18 = 10^6 precision
        // 10^6 * 10^12 = 10^18 --> scale for future token's decimals
        return ((_amount * 1e18) / _price) * 1e12;
    }

    /**
     * @notice Retrieve the current stage of the sale.
     * @dev Evaluates the current timestamp against the predefined sale schedule stages.
     * @return The current stage which can be one of the stages:
     *         - `Stages.ComingSoon`: Sale has not started yet.
     *         - `Stages.TokenPurchase`: Sale is active, allowing token purchases.
     *         - `Stages.Completed`: Sale has ended.
     */
    function _getCurrentStage() private view returns (Stages) {
        if (block.timestamp < saleSchedule.start) return Stages.ComingSoon;
        if (block.timestamp < saleSchedule.end) return Stages.TokenPurchase;

        return Stages.Completed;
    }

    /**
     * @notice Get the remaining cap for the total funds that can be collected.
     * @dev This function computes the remaining amount of funds that can be collected
     *      by subtracting the total funds already collected from the maximum allowed funds.
     * @return The remaining cap amount.
     */
    function _getRemainingCap() private view returns (uint256) {
        return maxTotalFunds - totalFundsCollected;
    }

    /**
     * @notice Set the stream hook for the user.
     * @param _user Address of the user.
     * @param _amount Amount of tokens to stream.
     * @param _vesting Vesting time for the tokens.
     */
    function _setVestingHook(address _user, uint256 _amount, uint256 _vesting) private {
        // Set stream hook
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieve the current stage of the sale.
     * @dev Evaluates the current timestamp against the predefined sale schedule stages.
     * @return The current stage which can be one of the stages:
     *         - `Stages.ComingSoon`: Sale has not started yet.
     *         - `Stages.OnlyKyc`: Only KYC available, purchase not yet allowed.
     *         - `Stages.TokenPurchase`: Sale is active, allowing token purchases.
     *         - `Stages.Completed`: Sale has ended.
     */
    function getCurrentStage() external view returns (Stages) {
        return _getCurrentStage();
    }

    /**
     * @notice Get the remaining deposit amount for a given user.
     * @param _user Address of the user.
     * @return The remaining deposit amount that the user can still deposit.
     */
    function getRemainingDepositAmount(address _user) external view returns (uint256) {
        return saleParameters.maxDepositAmount - userDeposits[_user].amountDeposited;
    }

    /**
     * @notice Get the remaining cap for the sale.
     * @return The remaining cap amount for the total funds collected in the sale.
     */
    function getRemainingCap() external view returns (uint256) {
        return _getRemainingCap();
    }
}
