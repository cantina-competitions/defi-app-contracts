// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../script/foundry/deploy-libraries/_Index.s.sol";
import {FileSystem} from "../script/foundry/utils/FileSystem.s.sol";
import {VmSafe} from "forge-std/StdUtils.sol";
import {MockToken} from "./mocks/MockToken.t.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";
import {DefiAppStaker} from "../src/DefiAppStaker.sol";
import {DefiAppHomeCenter} from "../src/DefiAppHomeCenter.sol";
import {MFDBaseInitializerParams, LockType} from "../src/dependencies/MultiFeeDistribution/MFDDataTypes.sol";
import {IGauge} from "../src/interfaces/aerodrome/IGauge.sol";

contract BasicFixture is Test {
    ///////// Constants /////////
    bool public constant TESTING_ONLY = true;

    ///////// Storage /////////
    VmSafe.Wallet public User1;
    VmSafe.Wallet public User2;
    VmSafe.Wallet public User3;
    VmSafe.Wallet public User4;
    VmSafe.Wallet public Admin;
    VmSafe.Wallet public Treasury;

    FileSystem public fs;

    /// App constants
    uint256 public constant ONE_MONTH_TYPE_INDEX = 0;
    uint256 public constant THREE_MONTH_TYPE_INDEX = 1;
    uint256 public constant SIX_MONTH_TYPE_INDEX = 2;
    uint256 public constant TWELVE_MONTH_TYPE_INDEX = 3;

    uint128 public constant ONE_MONTH_MULTIPLIER = 1;
    uint128 public constant THREE_MONTH_MULTIPLIER = 3;
    uint128 public constant SIX_MONTH_MULTIPLIER = 6;
    uint128 public constant TWELVE_MONTH_MULTIPLIER = 12;

    uint128 public constant DEFAULT_RPS = 1 ether;
    uint32 public constant DEFAULT_EPOCH_DURATION = 30 days;

    function setUp() public virtual {
        User1 = vm.createWallet("User1");
        User2 = vm.createWallet("User2");
        User3 = vm.createWallet("User3");
        User4 = vm.createWallet("User4");
        Admin = vm.createWallet("Admin");
        Treasury = vm.createWallet("Treasury");

        fs = new FileSystem();
    }

    function deploy_mock_tocken(string memory _name, string memory _symbol) internal returns (MockToken) {
        return new MockToken(_name, _symbol);
    }

    function deploy_defiapp_staker(address deployer, address emissionToken, address stakeToken, address gauge)
        internal
        returns (DefiAppStaker)
    {
        LockType[] memory initLockTypes = new LockType[](4);
        initLockTypes[ONE_MONTH_TYPE_INDEX] = LockType({duration: 30 days, multiplier: ONE_MONTH_MULTIPLIER});
        initLockTypes[THREE_MONTH_TYPE_INDEX] = LockType({duration: 90 days, multiplier: THREE_MONTH_MULTIPLIER});
        initLockTypes[SIX_MONTH_TYPE_INDEX] = LockType({duration: 180 days, multiplier: SIX_MONTH_MULTIPLIER});
        initLockTypes[TWELVE_MONTH_TYPE_INDEX] = LockType({duration: 360 days, multiplier: TWELVE_MONTH_MULTIPLIER});

        MFDBaseInitializerParams memory params = MFDBaseInitializerParams({
            emissionToken: emissionToken,
            stakeToken: stakeToken,
            rewardStreamTime: 7 days,
            rewardsLookback: 1 days,
            initLockTypes: initLockTypes,
            defaultLockTypeIndex: ONE_MONTH_TYPE_INDEX
        });

        vm.startPrank(deployer);
        DefiAppStaker staker = DefiAppStakerDeployer.deploy(fs, "DefiAppStaker", TESTING_ONLY, false, params);

        if (gauge != address(0)) {
            staker.setGauge(IGauge(gauge));
        }

        vm.stopPrank();

        return staker;
    }

    function deploy_defiapp_homecenter(address deployer, address emissionToken, DefiAppStaker staker)
        internal
        returns (DefiAppHomeCenter)
    {
        vm.startPrank(deployer);
        DefiAppHomeCenterInitParams memory params = DefiAppHomeCenterInitParams({
            homeToken: address(emissionToken),
            stakingAdress: address(staker),
            initRps: DEFAULT_RPS,
            initEpochDuration: DEFAULT_EPOCH_DURATION
        });
        DefiAppHomeCenter center =
            DefiAppHomeCenterDeployer.deploy(fs, "DefiAppHomeCenter", TESTING_ONLY, false, params);
        staker.setHomeCenter(center);
        vm.stopPrank();

        return center;
    }

    function load_weth9(address user, uint256 amount, IWETH9 weth9) internal {
        vm.deal(user, amount);
        vm.prank(user);
        weth9.deposit{value: amount}();
    }
}
