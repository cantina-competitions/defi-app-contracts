// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILayerZeroUltraLightNodeV2 {
    // Relayer functions
    function validateTransactionProof(
        uint16 _srcChainId,
        address _dstAddress,
        uint256 _gasLimit,
        bytes32 _lookupHash,
        bytes32 _blockData,
        bytes calldata _transactionProof
    ) external;

    // an Oracle delivers the block data using updateHash()
    function updateHash(uint16 _srcChainId, bytes32 _lookupHash, uint256 _confirmations, bytes32 _blockData) external;

    // can only withdraw the receivable of the msg.sender
    function withdrawNative(address payable _to, uint256 _amount) external;

    function withdrawZRO(address _to, uint256 _amount) external;

    // view functions
    function getAppConfig(uint16 _remoteChainId, address _userApplicationAddress)
        external
        view
        returns (ApplicationConfiguration memory);

    function accruedNativeFee(address _address) external view returns (uint256);

    struct ApplicationConfiguration {
        uint16 inboundProofLibraryVersion;
        uint64 inboundBlockConfirmations;
        address relayer;
        uint16 outboundProofType;
        uint64 outboundBlockConfirmations;
        address oracle;
    }

    event HashReceived(
        uint16 indexed srcChainId, address indexed oracle, bytes32 lookupHash, bytes32 blockData, uint256 confirmations
    );
    event RelayerParams(bytes adapterParams, uint16 outboundProofType);
    event Packet(bytes payload);
    event InvalidDst(
        uint16 indexed srcChainId, bytes srcAddress, address indexed dstAddress, uint64 nonce, bytes32 payloadHash
    );
    event PacketReceived(
        uint16 indexed srcChainId, bytes srcAddress, address indexed dstAddress, uint64 nonce, bytes32 payloadHash
    );
    event AppConfigUpdated(address indexed userApplication, uint256 indexed configType, bytes newConfig);
    event AddInboundProofLibraryForChain(uint16 indexed chainId, address lib);
    event EnableSupportedOutboundProof(uint16 indexed chainId, uint16 proofType);
    event SetChainAddressSize(uint16 indexed chainId, uint256 size);
    event SetDefaultConfigForChainId(
        uint16 indexed chainId,
        uint16 inboundProofLib,
        uint64 inboundBlockConfirm,
        address relayer,
        uint16 outboundProofType,
        uint64 outboundBlockConfirm,
        address oracle
    );
    event SetDefaultAdapterParamsForChainId(uint16 indexed chainId, uint16 indexed proofType, bytes adapterParams);
    event SetLayerZeroToken(address indexed tokenAddress);
    event SetRemoteUln(uint16 indexed chainId, bytes32 uln);
    event SetTreasury(address indexed treasuryAddress);
    event WithdrawZRO(address indexed msgSender, address indexed to, uint256 amount);
    event WithdrawNative(address indexed msgSender, address indexed to, uint256 amount);
}
