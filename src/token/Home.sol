// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {ERC20, ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Home Contract
/// @author security@defi.app
contract Home is Initializable, Pausable, OFT, ERC20Capped {
    /// Events
    event EmergencyAdminSet(address emergencyAdmin);
    event MinterSet(address minter, bool status);

    /// Custom Errors
    error Home_invaidInput();
    error Home_notEmergencyAdmin();
    error Home_notAllowedMinter();

    /// Storage
    address public emergencyAdmin;
    mapping(address => bool) public allowedMinters;

    modifier onlyEmergencyAdmin() {
        require(msg.sender == emergencyAdmin, Home_notEmergencyAdmin());
        _;
    }

    modifier onlyAllowedMinter() {
        require(allowedMinters[msg.sender], Home_notAllowedMinter());
        _;
    }

    constructor(string memory _name, string memory _symbol, address _lzEndpoint, address _delegate, uint256 supplyCap)
        OFT(_name, _symbol, _lzEndpoint, _delegate)
        Ownable(msg.sender)
        ERC20Capped(supplyCap)
    {}

    /**
     * @notice Token generation event.
     */
    function initialize(address[] calldata receivers, uint256[] calldata amounts) external initializer onlyOwner {
        require(receivers.length == amounts.length, Home_invaidInput());
        for (uint256 i = 0; i < receivers.length; i++) {
            _mint(receivers[i], amounts[i]);
        }
    }

    /**
     * @notice Mint new tokens for distribution.
     * @param to destination address
     * @param amount  amount of tokens to mint
     * @dev Only allowed minters can mint new tokens.
     */
    function mint(address to, uint256 amount) external onlyAllowedMinter {
        _mint(to, amount);
    }

    /// Setter functions

    function setMinter(address minter, bool status) external onlyOwner {
        require(minter != address(0) && allowedMinters[minter] != status, Home_invaidInput());
        allowedMinters[minter] = status;
        emit MinterSet(minter, status);
    }

    /**
     * @notice Set emergency admin address.
     * @param _emergencyAdmin The address of the emergency admin.
     */
    function setEmergencyAdmin(address _emergencyAdmin) external onlyOwner {
        require(_emergencyAdmin != address(0), Home_invaidInput());
        emergencyAdmin = _emergencyAdmin;
        emit EmergencyAdminSet(_emergencyAdmin);
    }

    /// Emergency functions

    /**
     * @notice Pause bridge operation.
     */
    function pauseBridge() public onlyEmergencyAdmin {
        _pause();
    }

    /**
     * @notice Unpause bridge operation.
     */
    function unpauseBridge() public onlyEmergencyAdmin {
        _unpause();
    }

    /// Internal functions

    /**
     * @dev overrides default OFT._debit(...) function to make pauseable
     */
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal
        override
        whenNotPaused
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }

    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}
