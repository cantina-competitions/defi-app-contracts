// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVestingManager, VestParams} from "../interfaces/IVestingManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IBlacklist} from "../interfaces/IBlacklist.sol";

/// @title PublicSale Contract
/// @notice Contract for the public sale of tokens.
/// @dev This contract allows users to deposit USDC and purchase tokens.
/// Based on: https://etherscan.io/address/0xcfd9cb8f15a9732bc449b05d97c29244de2259b2#code
/// @author security@defi.app
contract PublicSale is Ownable, Pausable {
    using SafeERC20 for IERC20;

    /**
     * @notice Info about user deposit
     */
    struct UserDepositInfo {
        uint256 amountDeposited; // Total amount deposited by the user
        bool claimed; // Whether the user has claimed the tokens
        Purchase[] purchases; // Total user Purchases
    }

    struct Purchase {
        uint128 purchasedTokens; // Total tokens purchased by the user
        uint256 vesting; // Vesting time for the tokens
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
        TokenPurchase, // Deposit and purchase tokens
        ClaimAndVest // Claim and start vesting

    }

    event ExternalContractsSet(address indexed user, address treasury, IERC20 usdc, address vestingContract);
    event TiersUpdate(address indexed user, Tier[3] tiers);
    event MaxTotalFundsUpdate(address indexed user, uint256 maxTotalFunds);
    event SaleParametersUpdate(address indexed user, uint256 minDepositAmount, uint256 maxDepositAmount);
    event VestingReadyUpdate(address indexed user, address saleToken, address vestingContract, uint32 vestingStart);
    event SaleScheduleUpdate(address indexed user, uint256 comingSoon, uint256 tokenPurchase);
    event BlacklistSet(address indexed user, address blacklist);
    event TokensPurchase(
        address indexed user,
        uint256 depositedAmount,
        uint256 purchasedTokens,
        uint256 vesting,
        uint256 totalFundsCollected
    );
    event SaleCompleted();
    event RecoverAsset(address asset, address withdrawTo, uint256 amount);

    /**
     * @dev Error thrown when a user has already claimed their tokens.
     * @param _user The address of the user
     */
    error UserHasClaimed(address _user);

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
     * @dev Error thrown when the sale has already been set.
     * @param _selector The function selector that triggered the error.
     * @param _input The input that was already set.
     */
    error AlreadySet(bytes4 _selector, bytes32 _input);

    uint32 public constant DEFAULT_STEP_DURATION = 30 days;

    uint256 internal constant SAFE_MINIMUM = 10e6;

    uint256 internal constant PERCENTAGE_PRECISION = 1e18;

    uint256 internal constant MAX_TIERS = 3;

    /**
     * @dev Recipient of collected funds.
     */
    address private immutable treasury;

    /**
     * @dev Address of USDC token.
     */
    IERC20 private immutable USDC;

    /**
     * @dev Blacklist contract
     */
    address private blacklist;

    /**
     * @notice Maximum funds allowed to be collected.
     * @dev 20,000,000 USDC(*) times 10^6, 6 is the number of decimals of USDC.
     */
    uint256 public maxTotalFunds;

    /**
     * @dev Address of the token being sold.
     */
    IERC20 public saleToken;

    /**
     * @notice  Address of the vesting contract.
     */
    address public vestingContract;

    /**
     * @dev Vesting start timestamp.
     */
    uint32 public vestingStart;

    /**
     * @dev Array of Tier structs representing different price tiers in Sale.
     */
    Tier[MAX_TIERS] public tiers;

    /**
     * @dev Array of uint256 representing how much deposited on each tier.
     */
    uint256[MAX_TIERS] public tiersDeposited;

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
     * @dev Total tokens purchased so far
     */
    uint256 public totalTokensPurchased;

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

    /**
     * @notice Constructor to set the sale parameters.
     * @param _admin Address of the admin.
     * @param _treasury Address of the treasury.(multisig)
     * @param _usdc Address of the USDC token.
     */
    constructor(address _admin, address _treasury, IERC20 _usdc) Ownable(_admin) {
        address ZERO_ADDRESS = address(0);

        require((_treasury != ZERO_ADDRESS) && (address(_usdc) != ZERO_ADDRESS));

        _pause();

        treasury = _treasury;
        USDC = _usdc;

        emit ExternalContractsSet(msg.sender, treasury, USDC, vestingContract);

        // Tier prices are scaled by 10^18 to keep precision during division
        _setTiers(
            [
                // price, cap, vesting
                Tier(0.03 ether, 3_000_000e6, 0 days), // 0
                Tier(0.02 ether, 2_000_000e6, 360 days), // 1
                Tier(0.01 ether, 1_000_000e6, 720 days) // 2
            ]
        );
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the sale parameters including minimum and maximum deposit amounts.
     * @dev This function can only be called by `owner` and when the contract is paused.
     * @param _minDepositAmount The minimum amount that can be deposited.
     * @param _maxDepositAmount The maximum amount that can be deposited.
     * Emits a {SaleParametersUpdate} event.
     */
    function setSaleParameters(uint256 _minDepositAmount, uint256 _maxDepositAmount) external whenPaused onlyOwner {
        require(SAFE_MINIMUM < _minDepositAmount && _minDepositAmount < _maxDepositAmount);

        saleParameters = SaleParameters(_minDepositAmount, _maxDepositAmount);
        emit SaleParametersUpdate(msg.sender, _minDepositAmount, _maxDepositAmount);
    }

    /**
     * @notice Sets the sale schedule including KYC and token purchase periods.
     * @dev This function can only be called by `owner`and when the contract is paused.
     * @param _tokenPurchaseStart The timestamp until which users can start purchasing.
     * @param _tokenPurchaseEnd The timestamp until which token purchases can be made.
     * Emits a {SaleScheduleUpdate} event.
     */
    function setSaleSchedule(uint256 _tokenPurchaseStart, uint256 _tokenPurchaseEnd) external whenPaused onlyOwner {
        require((_tokenPurchaseStart < _tokenPurchaseEnd));

        saleSchedule = SaleSchedule(_tokenPurchaseStart, _tokenPurchaseEnd);

        emit SaleScheduleUpdate(msg.sender, _tokenPurchaseStart, _tokenPurchaseEnd);
    }

    /**
     * @notice Sets the tiers for the sale.
     * @dev This function can only be called by `owner`and when the contract is paused.
     * @param _tiers An array of Tier structs representing the different tiers.
     * Emits a {TiersUpdate} event.
     */
    function setTiers(Tier[3] calldata _tiers) public atStage(Stages.ComingSoon) onlyOwner {
        bytes32 tiersHash_ = keccak256(bytes.concat(msg.data[4:]));
        bytes32 zeroBytesHash_ = keccak256(bytes.concat(new bytes(288)));
        require(tiersHash_ != zeroBytesHash_);

        _setTiers(_tiers);
    }

    /**
     * @notice Set the blacklist contract.
     * @param _blacklist Address of the blacklist contract.
     */
    function setBlacklist(address _blacklist) external onlyOwner {
        require(_blacklist != address(0), InvalidInput(this.setBlacklist.selector, bytes32(uint256(0))));
        blacklist = _blacklist;
        emit BlacklistSet(msg.sender, _blacklist);
    }

    /**
     * @notice Set the sale token.
     * @param _saleToken Address of the token to be sold
     * @param _vestingContract Address of the vesting contract.
     * @param _vestingStart UNIX timestamp of the vesting start.
     * @dev This function can only be called by `owner` and only once.
     * _saleToken must be 18 decimals.
     */
    function setVestingReady(IERC20 _saleToken, address _vestingContract, uint32 _vestingStart)
        external
        onlyOwner
        atStage(Stages.Completed)
    {
        require(
            address(saleToken) == address(0),
            AlreadySet(this.setVestingReady.selector, bytes32(uint256(uint160(address(_saleToken)))))
        );
        require(
            (address(_saleToken) != address(0)) && (_vestingContract != address(0)),
            InvalidInput(this.setVestingReady.selector, bytes32(uint256(0)))
        );

        require(
            _vestingStart > block.timestamp,
            InvalidInput(this.setVestingReady.selector, bytes32(uint256(_vestingStart)))
        );
        require(
            address(_saleToken) == IVestingManager(_vestingContract).vestingAsset(),
            InvalidInput(this.setVestingReady.selector, bytes32(uint256(uint160(address(_saleToken)))))
        );
        uint256 saleTokenDecimals = ERC20(address(_saleToken)).decimals();
        require(saleTokenDecimals == 18, InvalidInput(this.setVestingReady.selector, bytes32(saleTokenDecimals)));

        saleToken = _saleToken;
        vestingContract = _vestingContract;
        vestingStart = _vestingStart;

        emit VestingReadyUpdate(msg.sender, address(saleToken), vestingContract, vestingStart);
    }

    /**
     * @notice Admin authorized method to set the vesting for a user.
     * @param _user Address of the user.
     * @param _amount Amount of tokens to vest.
     * @param _vestingTime Vesting time for the tokens.
     * @param _start UNIX timestamp of  the `_vestingTime` to start for the tokens.
     */
    function setVesting(address _user, uint128 _amount, uint256 _vestingTime, uint32 _start) external onlyOwner {
        _setVestingHook(_user, _amount, _vestingTime, _start);
    }

    /**
     * @notice Set the token URI for the vesting tokens if required.
     * @param _vestIds Array of vesting ids.
     * @param _tokenURI URI for the tokens.
     * @dev This function can only be called by the owner.
     */
    function setVestTokenURI(uint256[] calldata _vestIds, string calldata _tokenURI) external onlyOwner {
        for (uint256 i = 0; i < _vestIds.length; i++) {
            IVestingManager(vestingContract).setVestTokenURI(_vestIds[i], _tokenURI);
        }
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
        _checkBlacklist(msg.sender);
        UserDepositInfo storage userDepositInfo = userDeposits[msg.sender];

        if (userDepositInfo.purchases.length == 0) {
            for (uint256 i = 0; i < MAX_TIERS; i++) {
                userDepositInfo.purchases.push(Purchase(0, tiers[i].vesting));
            }
        }

        _verifyDepositConditions(_amount, userDepositInfo.amountDeposited);
        _purchase(_amount, userDepositInfo, _tierIndex);
    }

    /**
     * @notice Claim and start vesting for users who have already deposited.
     * @dev This function can only be called when the sale is completed and the contract is in the ClaimAndVest stage.
     */
    function claimAndStartVesting() external atStage(Stages.ClaimAndVest) {
        UserDepositInfo storage userDepositInfo = userDeposits[msg.sender];
        require(!userDepositInfo.claimed, UserHasClaimed(msg.sender));
        userDepositInfo.claimed = true;

        Purchase memory purchase;
        for (uint256 i = 0; i < MAX_TIERS; i++) {
            purchase = userDepositInfo.purchases[i];
            if (purchase.purchasedTokens > 0) {
                _setVestingHook(msg.sender, purchase.purchasedTokens, purchase.vesting, vestingStart);
            }
        }
    }

    /**
     * @notice Recover assets from the contract.
     * @param recipient Address to send the assets to.
     * @param asset Address of the asset to withdraw (e.g., USDC).
     */
    function recoverAssets(address recipient, IERC20 asset) external onlyOwner {
        uint256 contractBalance = asset.balanceOf(address(this));
        asset.safeTransfer(recipient, contractBalance);
        emit RecoverAsset(address(asset), recipient, contractBalance);
    }

    /**
     * @notice Pause the contract, preventing deposits.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract, allowing deposits.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle the purchase logic.
     * @param _amountUSDC Amount to deposit.
     * @param _userDepositInfo User deposit info.
     * @param _tierIndex Tier index to purchase.
     * @dev Emits a Purchase event upon successful purchase.
     */
    function _purchase(uint256 _amountUSDC, UserDepositInfo storage _userDepositInfo, uint256 _tierIndex) private {
        (uint256 _purchasedTokens, uint256 _remainingAmount) = _calculateTokensToTransfer(_amountUSDC, _tierIndex);

        uint256 depositedAmount_ = _amountUSDC - _remainingAmount;

        totalFundsCollected += depositedAmount_;
        totalTokensPurchased += _purchasedTokens;
        tiersDeposited[_tierIndex] += depositedAmount_;

        _userDepositInfo.amountDeposited += depositedAmount_;
        _userDepositInfo.purchases[_tierIndex].purchasedTokens += _safeCastUint128(_purchasedTokens);

        uint256 vestingTime = _userDepositInfo.purchases[_tierIndex].vesting;

        USDC.safeTransferFrom(msg.sender, treasury, depositedAmount_);

        emit TokensPurchase(msg.sender, depositedAmount_, _purchasedTokens, vestingTime, totalFundsCollected);

        if (_getRemainingCap() == 0) {
            _pause();
            emit SaleCompleted();
        }
    }

    /**
     * @notice Internal function to verify deposit conditions like minimum/maximum amount
     * @param _amount Amount to deposit.
     * @param _amountDeposited Amount already deposited by the user.
     * @dev Throws custom errors if any condition fails.
     */
    function _verifyDepositConditions(uint256 _amount, uint256 _amountDeposited) private view {
        SaleParameters memory _saleParameters = saleParameters;
        uint256 _remainingAmount = _saleParameters.maxDepositAmount - _amountDeposited;

        // Allow depositing the exact remaining amount even if it is less than SAFE_MINIMUM
        if (_remainingAmount < SAFE_MINIMUM && _amount == _remainingAmount) return;

        if (_amount < SAFE_MINIMUM) {
            revert InvalidPurchaseInputHandler(msg.sig, bytes32("_amount"), bytes32("at least"), SAFE_MINIMUM);
        }

        if ((_amount + _amountDeposited) < _saleParameters.minDepositAmount) {
            revert InvalidPurchaseInputHandler(
                msg.sig, bytes32("_amount"), bytes32("below minDepositAmount"), _saleParameters.minDepositAmount
            );
        }

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
    function _setTiers(Tier[MAX_TIERS] memory _tiers) private {
        maxTotalFunds = 0;
        for (uint256 i = 0; i < MAX_TIERS; i++) {
            _checkTierVestDuration(_tiers[i]);
            tiers[i] = _tiers[i];
            maxTotalFunds += _tiers[i].cap;
        }

        emit TiersUpdate(msg.sender, _tiers);
        emit MaxTotalFundsUpdate(msg.sender, maxTotalFunds);
    }

    /**
     * @notice Calculates the number of tokens to transfer based on the deposited amount and tiers.
     * @dev This function accounts for multiple tiers and computes tokens across them if necessary.
     * @param _amountUsdc The amount USDC deposited by the user.
     * @param _tierIndex The index tier to purchase.
     * @return A tuple containing:
     *         - `resultingTokens_` The total number of tokens purchased.
     *         - `remainingAmount_` The remaining amount after token computation.
     */
    function _calculateTokensToTransfer(uint256 _amountUsdc, uint256 _tierIndex)
        private
        view
        returns (uint256, uint256)
    {
        Tier memory _tier = tiers[_tierIndex];
        uint256 _remainingTierCap = _tier.cap - tiersDeposited[_tierIndex];

        if (_remainingTierCap == 0) {
            revert InvalidPurchaseInput(this.depositUSDC.selector, "_tierIndex", "tier cap reached");
        }

        if (_amountUsdc <= _remainingTierCap) {
            return (_computeTokens(_amountUsdc, _tier.price), 0);
        } else {
            uint256 _remainingAmount = _amountUsdc - _remainingTierCap;
            return (_computeTokens(_remainingTierCap, _tier.price), _remainingAmount);
        }
    }

    /**
     * @param _amountUSDC The amount in USDC
     * @param _price The price of the token in USD
     */
    function _computeTokens(uint256 _amountUSDC, uint256 _price) private pure returns (uint256) {
        // _price = price * 10^18 --> precision scaling
        // _amountUSDC = (input_amount * 10^6 (USDC)
        // (_amount * 1e18) / _price = (10^6 * 10^18) / 10^18 = 10^6 precision
        // 10^6 * 10^12 = 10^18 --> scale for future token's decimals
        // SaleToken is enforced to have 18 decimals
        return ((_amountUSDC * 1e30) / _price);
    }

    /**
     * @notice Retrieve the current stage of the sale.
     * @dev Evaluates the current timestamp against the predefined sale schedule stages.
     * @return The current stage which can be one of the stages:
     *         - `Stages.ComingSoon`: Sale has not started yet.
     *         - `Stages.TokenPurchase`: Sale is active, allowing token purchases.
     *         - `Stages.Completed`: Sale has ended.
     *        - `Stages.ClaimAndVest`: Sale has ended and users can claim and start vesting.
     */
    function _getCurrentStage() private view returns (Stages) {
        if (saleSchedule.start == 0 && saleSchedule.end == 0) return Stages.ComingSoon;
        if (vestingStart != 0) return Stages.ClaimAndVest;
        if (totalFundsCollected >= maxTotalFunds) return Stages.Completed;
        if (maxTotalFunds > totalFundsCollected && (maxTotalFunds - totalFundsCollected) <= SAFE_MINIMUM) {
            return Stages.Completed;
        }

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
     * @notice Get the remaining cap for a specific tier.
     * @param _tierIndex The index of the tier.
     * @return The remaining cap amount for the tier.
     */
    function _getRemainingTierCap(uint256 _tierIndex) private view returns (uint256) {
        return tiers[_tierIndex].cap - tiersDeposited[_tierIndex];
    }

    /**
     * @notice Check if the vesting duration of a tier is a multiple of the default step duration.
     * @param _tier to which vesting duration to check.
     */
    function _checkTierVestDuration(Tier memory _tier) private pure {
        if (_tier.vesting % DEFAULT_STEP_DURATION != 0) {
            revert InvalidInput(msg.sig, bytes32(_tier.vesting));
        }
    }

    /**
     * @notice Set the vesting for the user.
     * @param _user Address of the user.
     * @param _amount Amount of tokens to vest.
     * @param _vesting Vesting time for the tokens.
     * @param _start Vesting start time for the tokens.
     */
    function _setVestingHook(address _user, uint128 _amount, uint256 _vesting, uint32 _start) private {
        saleToken.safeTransferFrom(treasury, address(this), _amount);
        saleToken.forceApprove(vestingContract, _amount);
        uint32 numberOfSteps = _computeVestingSteps(_vesting);
        uint128 stepPercentage =
            numberOfSteps > 0 ? uint128(PERCENTAGE_PRECISION / numberOfSteps) : uint128(PERCENTAGE_PRECISION);
        uint32 stepDuration = _vesting == 0 ? 1 : DEFAULT_STEP_DURATION;
        IVestingManager(vestingContract).createVesting(
            VestParams({
                recipient: _user,
                start: _start,
                cliffDuration: 0,
                stepDuration: stepDuration,
                steps: numberOfSteps,
                stepPercentage: stepPercentage,
                amount: uint128(_amount),
                tokenURI: ""
            })
        );
    }

    /**
     * @dev Returns the number of steps required to vest the tokens.
     * For `_vesting` equal to 0, the function returns 1.
     * For any other value, the function ceils the division of `_vesting` by `DEFAULT_STEP_DURATION`.
     * @param _vesting time for the tokens.
     */
    function _computeVestingSteps(uint256 _vesting) private pure returns (uint32) {
        if (_vesting == 0) {
            return 1;
        }
        return uint32((_vesting + DEFAULT_STEP_DURATION - 1) / DEFAULT_STEP_DURATION);
    }

    /**
     * @dev Safely cast a uint256 to a uint128.
     * @param _value The value to cast.
     * @return The casted value.
     */
    function _safeCastUint128(uint256 _value) private pure returns (uint128) {
        require(_value <= type(uint128).max, "Value exceeds uint128");
        return uint128(_value);
    }

    /**
     * @dev If `blacklist` is defined check if the user is blacklisted.
     * @param _user Address of the user.
     */
    function _checkBlacklist(address _user) private view {
        if (blacklist != address(0)) {
            require(!IBlacklist(blacklist).isBlacklisted(_user), "User is blacklisted");
        }
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
     * @notice Get the user deposit information.
     * @param _user Address of the user.
     * @return UserDepositInfo struct containing the user's deposit information.
     */
    function getUserDepositInfo(address _user) external view returns (UserDepositInfo memory) {
        return userDeposits[_user];
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

    /**
     * @notice Get the remaining cap for a specific tier.
     * @param _tierIndex The index of the tier.
     * @return The remaining cap amount for the tier.
     */
    function getRemainingTierCap(uint256 _tierIndex) external view returns (uint256) {
        return _getRemainingTierCap(_tierIndex);
    }
}
