// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {BasicFixture, MockToken, MockOracleRouter} from "../BasicFixture.t.sol";
import {Packet} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
// The unique path location of your OApp
import {Home} from "../../src/token/Home.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

/// @notice Unit test for Home token using the TestHelperOz5.
/// @dev Inherits from TestHelper to utilize its setup and utility functions.
contract TestUnitHomeToken is TestHelperOz5, BasicFixture {
    using OptionsBuilder for bytes;

    // Declaration of mock endpoint IDs.
    uint16 chainAEid = 1;
    uint16 chainBEid = 2;

    // Declaration of mock contracts.
    Home public homeA; // OFT ChainA
    Home public homeB; // OFT ChainB

    // Home test constants
    uint256 public constant HOME_MAX_SUPPLY = 1_000_000 ether;
    uint256 public constant INIT_BALANCE = HOME_MAX_SUPPLY / 4;

    /// @notice Calls setUp from TestHelper and initializes contract instances for testing.
    function setUp() public override(TestHelperOz5, BasicFixture) {
        _internalSetUp();
        super.setUp();
        vm.deal(User1.addr, 1000 ether);
        vm.deal(User2.addr, 1000 ether);

        // Initialize 2 endpoints, using UltraLightNode as the library type
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Initializes 2 OFT tokens for chainA and chainB
        vm.startPrank(Admin.addr);
        homeA = Home(
            _deployOApp(
                type(Home).creationCode,
                abi.encode("DefiApp-Home.chainA", "HOMEa", address(endpoints[chainAEid]), Admin.addr, HOME_MAX_SUPPLY)
            )
        );
        homeB = Home(
            _deployOApp(
                type(Home).creationCode,
                abi.encode("DefiApp-Home.chainB", "HOMEb", address(endpoints[chainBEid]), Admin.addr, HOME_MAX_SUPPLY)
            )
        );

        // Configure and wire the OFTs together
        address[] memory ofts = new address[](2);
        ofts[0] = address(homeA);
        ofts[1] = address(homeB);

        wireOApps(ofts);

        // Initialize Home
        address[] memory receivers = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        receivers[0] = User1.addr;
        receivers[1] = User2.addr;
        amounts[0] = INIT_BALANCE;
        amounts[1] = INIT_BALANCE;

        homeA.initialize(receivers, amounts);
        homeB.initialize(receivers, amounts);
        vm.stopPrank();
    }

    function test_homeInitialization() public view {
        // Check that the contract owner is correctly set
        assertEq(homeA.owner(), Admin.addr);
        assertEq(homeB.owner(), Admin.addr);

        // Verify initial token balances for user1 and user2
        assertEq(homeA.balanceOf(User1.addr), INIT_BALANCE);
        assertEq(homeA.balanceOf(User2.addr), INIT_BALANCE);
        assertEq(homeB.balanceOf(User1.addr), INIT_BALANCE);
        assertEq(homeB.balanceOf(User2.addr), INIT_BALANCE);

        // Verify that the token address is correctly set to the respective OFT instances
        assertEq(homeA.token(), address(homeA));
        assertEq(homeB.token(), address(homeB));

        assertEq(homeA.cap(), HOME_MAX_SUPPLY);
        assertEq(homeB.cap(), HOME_MAX_SUPPLY);
    }

    function test_homeSendOft() public {
        uint256 tokensToSend = 1 ether;

        // Build options for the send operation
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Set up parameters for the send operation
        SendParam memory sendParam =
            SendParam(chainBEid, addressToBytes32(User2.addr), tokensToSend, tokensToSend, options, "", "");

        // Quote the fee for sending tokens
        MessagingFee memory fee = homeA.quoteSend(sendParam, false);

        // Verify initial balances before the send operation
        assertEq(homeA.balanceOf(User1.addr), INIT_BALANCE);
        assertEq(homeB.balanceOf(User2.addr), INIT_BALANCE);

        // Perform the send operation
        vm.prank(User1.addr);
        homeA.send{value: fee.nativeFee}(sendParam, fee, payable(address(User1.addr)));

        // Verify that the packets were correctly sent to the destination chain.
        // @param _dstEid The endpoint ID of the destination chain.
        // @param _dstAddress The OApp address on the destination chain.
        verifyPackets(chainBEid, addressToBytes32(address(homeB)));

        // Check balances after the send operation
        assertEq(homeA.balanceOf(User1.addr), INIT_BALANCE - tokensToSend);
        assertEq(homeB.balanceOf(User2.addr), INIT_BALANCE + tokensToSend);
    }
}
