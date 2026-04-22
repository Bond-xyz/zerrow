// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/TestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

// V1 contracts
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/coinFactory.sol";
import "../contracts/zerrowOracleRedstone.sol";
import "../contracts/template/depositOrLoanCoin.sol";

// V2 contracts (existing test mocks)
import "../contracts/test/LendingManagerV2.sol";
import "../contracts/test/LendingVaultsV2.sol";
import "../contracts/test/CoinFactoryV2.sol";
import "../contracts/test/ZerrowOracleRedstoneV2.sol";
import "../contracts/test/DepositOrLoanCoinV2.sol";
import "../contracts/test/MockERC20.sol";

// ---------------------------------------------------------------------------
// Minimal mocks needed for integration (oracle, reward, core algorithm)
// ---------------------------------------------------------------------------

/// @dev Mock oracle that returns fixed prices
contract MockOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 p = prices[token];
        require(p > 0, "MockOracle: no price");
        return p;
    }
}

/// @dev Mock reward contract (no-op)
contract MockReward {
    function factoryUsedRegister(address, uint256) external {}
    function recordUpdate(address, uint256) external returns (bool) {
        return true;
    }
}

/// @dev Mock core algorithm that returns trivial interest values
contract MockCoreAlgorithm {
    function assetsValueUpdate(address) external pure returns (uint256[2] memory result) {
        result[0] = 100; // deposit interest
        result[1] = 200; // lending interest
    }

    function depositInterestRate(address, uint256) external pure returns (uint256) {
        return 100;
    }

    function lendingInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 200;
    }
}

// ===========================================================================
//  1.  UUPS Proxy Deployment + Initialization Tests
// ===========================================================================

contract LendingManagerProxyTest is TestBase {
    lendingManager public impl;
    ERC1967Proxy public proxy;
    lendingManager public manager; // proxy cast
    address public setter = address(0xA1);
    address public nonSetter = address(0xB1);

    function setUp() public {
        impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        manager = lendingManager(address(proxy));
    }

    function test_InitializeSetsState() public {
        assertEq(manager.setter(), setter);
        assertEq(manager.normalFloorOfHealthFactor(), 1.2 ether);
        assertEq(manager.homogeneousFloorOfHealthFactor(), 1.03 ether);
    }

    function test_DoubleInitializeReverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        manager.initialize(address(0xDEAD));
    }

    function test_ImplementationCannotBeInitialized() public {
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize(address(0xDEAD));
    }
}

contract LendingVaultsProxyTest is TestBase {
    lendingVaults public impl;
    ERC1967Proxy public proxy;
    lendingVaults public vaults;
    address public setter = address(0xA2);

    function setUp() public {
        impl = new lendingVaults();
        bytes memory initData = abi.encodeWithSelector(
            lendingVaults.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        vaults = lendingVaults(payable(address(proxy)));
    }

    function test_InitializeSetsState() public {
        assertEq(vaults.setter(), setter);
    }

    function test_DoubleInitializeReverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        vaults.initialize(address(0xDEAD));
    }
}

contract CoinFactoryProxyTest is TestBase {
    coinFactory public impl;
    ERC1967Proxy public proxy;
    coinFactory public factory;
    address public admin = address(0xA3);

    function setUp() public {
        impl = new coinFactory();
        bytes memory initData = abi.encodeWithSelector(
            coinFactory.initialize.selector,
            admin
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        factory = coinFactory(address(proxy));
    }

    function test_InitializeSetsState() public {
        assertEq(factory.setPermissionAddress(), admin);
    }

    function test_DoubleInitializeReverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        factory.initialize(address(0xDEAD));
    }
}

contract ZerrowOracleProxyTest is TestBase {
    zerrowOracleRedstone public impl;
    ERC1967Proxy public proxy;
    zerrowOracleRedstone public oracle;
    address public setter = address(0xA4);

    function setUp() public {
        impl = new zerrowOracleRedstone();
        bytes memory initData = abi.encodeWithSelector(
            zerrowOracleRedstone.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        oracle = zerrowOracleRedstone(payable(address(proxy)));
    }

    function test_InitializeSetsState() public {
        assertEq(oracle.setter(), setter);
        // Default maxStaleness set in initialize
        assertEq(oracle.maxStaleness(), 25200);
    }

    function test_DoubleInitializeReverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        oracle.initialize(address(0xDEAD));
    }
}

// ===========================================================================
//  2.  UUPS Upgrade Flow Tests
// ===========================================================================

contract LendingManagerUpgradeTest is TestBase {
    lendingManager public impl;
    ERC1967Proxy public proxy;
    lendingManager public manager;
    address public setter = address(0xA1);
    address public nonSetter = address(0xB1);

    MockOracle public mockOracle;
    MockCoreAlgorithm public mockCore;

    function setUp() public {
        impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        manager = lendingManager(address(proxy));

        // Set up dependencies
        mockOracle = new MockOracle();
        mockCore = new MockCoreAlgorithm();

        vm.prank(setter);
        manager.setup(
            address(0x1), // coinFactory placeholder
            address(0x2), // lendingVault placeholder
            address(0x3), // riskIsolationModeAcceptAssets
            address(mockCore),
            address(mockOracle)
        );
    }

    function test_SetterCanUpgrade() public {
        LendingManagerV2 implV2 = new LendingManagerV2();

        vm.prank(setter);
        manager.upgradeTo(address(implV2));

        // Cast to V2 interface to call new function
        LendingManagerV2 managerV2 = LendingManagerV2(address(proxy));
        assertEq(managerV2.version(), "v2");
    }

    function test_NonSetterCannotUpgrade() public {
        LendingManagerV2 implV2 = new LendingManagerV2();

        vm.prank(nonSetter);
        vm.expectRevert("not setter");
        manager.upgradeTo(address(implV2));
    }

    function test_StatePreservedAfterUpgrade() public {
        // Set state on V1
        vm.prank(setter);
        manager.setFloorOfHealthFactor(2 ether, 1.5 ether);
        assertEq(manager.normalFloorOfHealthFactor(), 2 ether);
        assertEq(manager.homogeneousFloorOfHealthFactor(), 1.5 ether);

        // Verify setup state
        assertEq(manager.oracleAddr(), address(mockOracle));
        assertEq(manager.coreAlgorithm(), address(mockCore));
        assertEq(manager.setter(), setter);

        // Upgrade to V2
        LendingManagerV2 implV2 = new LendingManagerV2();
        vm.prank(setter);
        manager.upgradeTo(address(implV2));

        // Verify old state preserved
        LendingManagerV2 managerV2 = LendingManagerV2(address(proxy));
        assertEq(managerV2.setter(), setter);
        assertEq(managerV2.normalFloorOfHealthFactor(), 2 ether);
        assertEq(managerV2.homogeneousFloorOfHealthFactor(), 1.5 ether);
        assertEq(managerV2.oracleAddr(), address(mockOracle));
        assertEq(managerV2.coreAlgorithm(), address(mockCore));
    }

    function test_V2NewFunctionalityWorks() public {
        LendingManagerV2 implV2 = new LendingManagerV2();
        vm.prank(setter);
        manager.upgradeTo(address(implV2));

        LendingManagerV2 managerV2 = LendingManagerV2(address(proxy));

        // New variable defaults to 0
        assertEq(managerV2.protocolFeeRate(), 0);

        // Setter can use new function
        vm.prank(setter);
        managerV2.setProtocolFeeRate(500);
        assertEq(managerV2.protocolFeeRate(), 500);
    }

    function test_V2NewFunctionAccessControl() public {
        LendingManagerV2 implV2 = new LendingManagerV2();
        vm.prank(setter);
        manager.upgradeTo(address(implV2));

        LendingManagerV2 managerV2 = LendingManagerV2(address(proxy));

        vm.prank(nonSetter);
        vm.expectRevert("Lending Manager: Only Setter Use");
        managerV2.setProtocolFeeRate(500);
    }

    function test_DoubleUpgrade() public {
        // Upgrade V1 -> V2
        LendingManagerV2 implV2a = new LendingManagerV2();
        vm.prank(setter);
        manager.upgradeTo(address(implV2a));

        LendingManagerV2 managerV2 = LendingManagerV2(address(proxy));
        vm.prank(setter);
        managerV2.setProtocolFeeRate(300);

        // Upgrade V2 -> another V2 instance (simulating V3)
        LendingManagerV2 implV2b = new LendingManagerV2();
        vm.prank(setter);
        managerV2.upgradeTo(address(implV2b));

        // State still preserved
        assertEq(managerV2.protocolFeeRate(), 300);
        assertEq(managerV2.setter(), setter);
    }
}

contract LendingVaultsUpgradeTest is TestBase {
    lendingVaults public impl;
    ERC1967Proxy public proxy;
    lendingVaults public vaults;
    address public setter = address(0xA2);
    address public nonSetter = address(0xB2);

    function setUp() public {
        impl = new lendingVaults();
        bytes memory initData = abi.encodeWithSelector(
            lendingVaults.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        vaults = lendingVaults(payable(address(proxy)));
    }

    function test_SetterCanUpgrade() public {
        LendingVaultsV2 implV2 = new LendingVaultsV2();
        vm.prank(setter);
        vaults.upgradeTo(address(implV2));

        LendingVaultsV2 vaultsV2 = LendingVaultsV2(payable(address(proxy)));
        assertEq(vaultsV2.version(), "v2");
    }

    function test_NonSetterCannotUpgrade() public {
        LendingVaultsV2 implV2 = new LendingVaultsV2();
        vm.prank(nonSetter);
        vm.expectRevert("not setter");
        vaults.upgradeTo(address(implV2));
    }

    function test_StatePreservedAfterUpgrade() public {
        // Set some state
        address mgr = address(0xCAFE);
        address rebal = address(0xBEEF);
        vm.startPrank(setter);
        vaults.setManager(mgr);
        vaults.setRebalancer(rebal);
        vm.stopPrank();

        assertEq(vaults.lendingManager(), mgr);
        assertEq(vaults.rebalancer(), rebal);

        // Upgrade
        LendingVaultsV2 implV2 = new LendingVaultsV2();
        vm.prank(setter);
        vaults.upgradeTo(address(implV2));

        LendingVaultsV2 vaultsV2 = LendingVaultsV2(payable(address(proxy)));
        assertEq(vaultsV2.setter(), setter);
        assertEq(vaultsV2.lendingManager(), mgr);
        assertEq(vaultsV2.rebalancer(), rebal);
    }

    function test_V2NewFunctionalityWorks() public {
        LendingVaultsV2 implV2 = new LendingVaultsV2();
        vm.prank(setter);
        vaults.upgradeTo(address(implV2));

        LendingVaultsV2 vaultsV2 = LendingVaultsV2(payable(address(proxy)));
        assertEq(vaultsV2.maxWithdrawPerBlock(), 0);

        vm.prank(setter);
        vaultsV2.setMaxWithdrawPerBlock(1000 ether);
        assertEq(vaultsV2.maxWithdrawPerBlock(), 1000 ether);
    }
}

contract CoinFactoryUpgradeTest is TestBase {
    coinFactory public impl;
    ERC1967Proxy public proxy;
    coinFactory public factory;
    address public admin = address(0xA3);
    address public nonAdmin = address(0xB3);

    function setUp() public {
        impl = new coinFactory();
        bytes memory initData = abi.encodeWithSelector(
            coinFactory.initialize.selector,
            admin
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        factory = coinFactory(address(proxy));
    }

    function test_AdminCanUpgrade() public {
        CoinFactoryV2 implV2 = new CoinFactoryV2();
        vm.prank(admin);
        factory.upgradeTo(address(implV2));

        CoinFactoryV2 factoryV2 = CoinFactoryV2(address(proxy));
        assertEq(factoryV2.version(), "v2");
    }

    function test_NonAdminCannotUpgrade() public {
        CoinFactoryV2 implV2 = new CoinFactoryV2();
        vm.prank(nonAdmin);
        vm.expectRevert("not admin");
        factory.upgradeTo(address(implV2));
    }

    function test_StatePreservedAfterUpgrade() public {
        MockReward reward = new MockReward();

        vm.startPrank(admin);
        factory.settings(address(0xCAFE), address(reward));
        factory.rewardTypeSetup(1, 2);
        factory.setBeacon(address(0xBEAC));
        vm.stopPrank();

        assertEq(factory.lendingManager(), address(0xCAFE));
        assertEq(factory.rewardContract(), address(reward));
        assertEq(factory.depositType(), 1);
        assertEq(factory.loanType(), 2);
        assertEq(factory.beacon(), address(0xBEAC));

        // Upgrade
        CoinFactoryV2 implV2 = new CoinFactoryV2();
        vm.prank(admin);
        factory.upgradeTo(address(implV2));

        CoinFactoryV2 factoryV2 = CoinFactoryV2(address(proxy));
        assertEq(factoryV2.setPermissionAddress(), admin);
        assertEq(factoryV2.lendingManager(), address(0xCAFE));
        assertEq(factoryV2.rewardContract(), address(reward));
        assertEq(factoryV2.depositType(), 1);
        assertEq(factoryV2.loanType(), 2);
        assertEq(factoryV2.beacon(), address(0xBEAC));
    }

    function test_V2NewFunctionalityWorks() public {
        CoinFactoryV2 implV2 = new CoinFactoryV2();
        vm.prank(admin);
        factory.upgradeTo(address(implV2));

        CoinFactoryV2 factoryV2 = CoinFactoryV2(address(proxy));
        assertEq(factoryV2.maxTokensPerAsset(), 0);

        vm.prank(admin);
        factoryV2.setMaxTokensPerAsset(50);
        assertEq(factoryV2.maxTokensPerAsset(), 50);
    }
}

contract ZerrowOracleUpgradeTest is TestBase {
    zerrowOracleRedstone public impl;
    ERC1967Proxy public proxy;
    zerrowOracleRedstone public oracle;
    address public setter = address(0xA4);
    address public nonSetter = address(0xB4);

    function setUp() public {
        impl = new zerrowOracleRedstone();
        bytes memory initData = abi.encodeWithSelector(
            zerrowOracleRedstone.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        oracle = zerrowOracleRedstone(payable(address(proxy)));
    }

    function test_SetterCanUpgrade() public {
        ZerrowOracleRedstoneV2 implV2 = new ZerrowOracleRedstoneV2();
        vm.prank(setter);
        oracle.upgradeTo(address(implV2));

        ZerrowOracleRedstoneV2 oracleV2 = ZerrowOracleRedstoneV2(address(proxy));
        assertEq(oracleV2.version(), "v2");
    }

    function test_NonSetterCannotUpgrade() public {
        ZerrowOracleRedstoneV2 implV2 = new ZerrowOracleRedstoneV2();
        vm.prank(nonSetter);
        vm.expectRevert("not setter");
        oracle.upgradeTo(address(implV2));
    }

    function test_StatePreservedAfterUpgrade() public {
        address token = address(0x1234);
        address feed = address(0x5678);

        vm.prank(setter);
        oracle.setTokenFeed(token, feed);
        assertEq(oracle.tokenToFeed(token), feed);
        assertEq(oracle.setter(), setter);

        // Upgrade
        ZerrowOracleRedstoneV2 implV2 = new ZerrowOracleRedstoneV2();
        vm.prank(setter);
        oracle.upgradeTo(address(implV2));

        ZerrowOracleRedstoneV2 oracleV2 = ZerrowOracleRedstoneV2(address(proxy));
        assertEq(oracleV2.setter(), setter);
        assertEq(oracleV2.tokenToFeed(token), feed);
    }

    function test_V2NewFunctionalityWorks() public {
        ZerrowOracleRedstoneV2 implV2 = new ZerrowOracleRedstoneV2();
        vm.prank(setter);
        oracle.upgradeTo(address(implV2));

        ZerrowOracleRedstoneV2 oracleV2 = ZerrowOracleRedstoneV2(address(proxy));
        assertEq(oracleV2.priceDeviationThreshold(), 0);

        vm.prank(setter);
        oracleV2.setPriceDeviationThreshold(500);
        assertEq(oracleV2.priceDeviationThreshold(), 500);
    }
}

// ===========================================================================
//  3.  BeaconProxy Tests (depositOrLoanCoin)
// ===========================================================================

contract BeaconProxyTest is TestBase {
    depositOrLoanCoin public impl;
    UpgradeableBeacon public beacon;
    address public beaconOwner = address(0xA5);

    // We need a mock manager that provides getCoinValues for balanceOf/totalSupply
    MockLendingManagerForCoin public mockManager;
    MockReward public mockReward;
    MockERC20 public underlyingToken;

    address public setter = address(0xA1);

    function setUp() public {
        mockManager = new MockLendingManagerForCoin();
        mockReward = new MockReward();
        underlyingToken = new MockERC20("Mock USDC", "USDC", 6);

        impl = new depositOrLoanCoin();

        vm.prank(beaconOwner);
        beacon = new UpgradeableBeacon(address(impl));
    }

    function _deployBeaconProxy(
        string memory name,
        string memory symbol,
        uint256 depositOrLoan
    ) internal returns (depositOrLoanCoin) {
        bytes memory initData = abi.encodeWithSelector(
            depositOrLoanCoin.initialize.selector,
            name,
            symbol,
            setter,
            address(underlyingToken),
            address(mockManager),
            depositOrLoan,
            address(mockReward)
        );
        BeaconProxy bp = new BeaconProxy(address(beacon), initData);
        return depositOrLoanCoin(address(bp));
    }

    function test_BeaconProxyDeployment() public {
        depositOrLoanCoin coin = _deployBeaconProxy("Test Deposit", "TD", 0);

        assertEq(coin.setter(), setter);
        assertEq(coin.OCoin(), address(underlyingToken));
        assertEq(coin.manager(), address(mockManager));
        assertEq(coin.depositOrLoan(), 0);
        assertEq(coin.rewardContract(), address(mockReward));
    }

    function test_MultipleProxiesShareImplementation() public {
        depositOrLoanCoin coin1 = _deployBeaconProxy("Deposit 1", "D1", 0);
        depositOrLoanCoin coin2 = _deployBeaconProxy("Loan 1", "L1", 1);
        depositOrLoanCoin coin3 = _deployBeaconProxy("Deposit 2", "D2", 0);

        // All proxies point to the same beacon
        assertEq(beacon.implementation(), address(impl));

        // But have independent state
        assertEq(coin1.depositOrLoan(), 0);
        assertEq(coin2.depositOrLoan(), 1);
        assertEq(coin3.depositOrLoan(), 0);
    }

    function test_BeaconUpgradeAffectsAllProxies() public {
        depositOrLoanCoin coin1 = _deployBeaconProxy("Deposit 1", "D1", 0);
        depositOrLoanCoin coin2 = _deployBeaconProxy("Loan 1", "L1", 1);

        // Verify V1 does not have version()
        // (We cannot easily call a non-existent function, so we check V2 after upgrade)

        // Deploy V2 implementation
        DepositOrLoanCoinV2 implV2 = new DepositOrLoanCoinV2();

        // Upgrade beacon
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(implV2));

        // Both proxies now have V2 logic
        DepositOrLoanCoinV2 coin1V2 = DepositOrLoanCoinV2(address(coin1));
        DepositOrLoanCoinV2 coin2V2 = DepositOrLoanCoinV2(address(coin2));

        assertEq(coin1V2.version(), "v2");
        assertEq(coin2V2.version(), "v2");
    }

    function test_BeaconUpgradePreservesState() public {
        depositOrLoanCoin coin = _deployBeaconProxy("Test Coin", "TC", 0);

        // Set some state on the coin via setter
        vm.prank(setter);
        coin.mintLockerSetup(true);
        assertTrue(coin.mintlock());
        assertEq(coin.setter(), setter);
        assertEq(coin.OCoin(), address(underlyingToken));
        assertEq(coin.depositOrLoan(), 0);

        // Upgrade beacon
        DepositOrLoanCoinV2 implV2 = new DepositOrLoanCoinV2();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(implV2));

        // Verify state preserved
        DepositOrLoanCoinV2 coinV2 = DepositOrLoanCoinV2(address(coin));
        assertTrue(coinV2.mintlock());
        assertEq(coinV2.setter(), setter);
        assertEq(coinV2.OCoin(), address(underlyingToken));
        assertEq(coinV2.depositOrLoan(), 0);
    }

    function test_BeaconUpgradeV2NewVariable() public {
        depositOrLoanCoin coin = _deployBeaconProxy("Test Coin", "TC", 0);

        // Upgrade
        DepositOrLoanCoinV2 implV2 = new DepositOrLoanCoinV2();
        vm.prank(beaconOwner);
        beacon.upgradeTo(address(implV2));

        DepositOrLoanCoinV2 coinV2 = DepositOrLoanCoinV2(address(coin));

        // New variable defaults to 0
        assertEq(coinV2.feeAccumulator(), 0);

        // Setter can use new function
        vm.prank(setter);
        coinV2.setFeeAccumulator(1000);
        assertEq(coinV2.feeAccumulator(), 1000);
    }

    function test_NonOwnerCannotUpgradeBeacon() public {
        DepositOrLoanCoinV2 implV2 = new DepositOrLoanCoinV2();

        vm.prank(address(0xDEAD));
        vm.expectRevert("Ownable: caller is not the owner");
        beacon.upgradeTo(address(implV2));
    }

    function test_BeaconProxyDoubleInitReverts() public {
        depositOrLoanCoin coin = _deployBeaconProxy("Test Coin", "TC", 0);

        vm.expectRevert("Initializable: contract is already initialized");
        coin.initialize(
            "Duplicate",
            "DUP",
            address(0xDEAD),
            address(0x1),
            address(0x2),
            0,
            address(0x3)
        );
    }
}

/// @dev Mock lending manager that provides getCoinValues for depositOrLoanCoin
contract MockLendingManagerForCoin {
    function getCoinValues(address) external pure returns (uint256[2] memory values) {
        values[0] = 1 ether; // deposit coin value
        values[1] = 1 ether; // loan coin value
    }
}

// ===========================================================================
//  4.  Pausability Tests
// ===========================================================================

contract PausabilityTest is TestBase {
    lendingManager public impl;
    ERC1967Proxy public proxy;
    lendingManager public manager;
    address public setter = address(0xA1);
    address public nonSetter = address(0xB1);

    MockOracle public mockOracle;
    MockCoreAlgorithm public mockCore;
    MockERC20 public mockToken;

    function setUp() public {
        impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        manager = lendingManager(address(proxy));

        mockOracle = new MockOracle();
        mockCore = new MockCoreAlgorithm();
        mockToken = new MockERC20("Mock Token", "MTK", 18);

        vm.prank(setter);
        manager.setup(
            address(0x1), // coinFactory
            address(0x2), // lendingVault
            address(0x3), // riskIsolationModeAcceptAssets
            address(mockCore),
            address(mockOracle)
        );
    }

    function test_SetterCanPause() public {
        vm.prank(setter);
        manager.pause();
        // Paused state - assetsDeposit should revert with whenNotPaused
        // We test indirectly; calling whenNotPaused function should revert
        vm.prank(setter);
        vm.expectRevert("Pausable: paused");
        manager.assetsDeposit(address(mockToken), 100, setter);
    }

    function test_NonSetterCannotPause() public {
        vm.prank(nonSetter);
        vm.expectRevert("Lending Manager: Only Setter Use");
        manager.pause();
    }

    function test_NonSetterCannotUnpause() public {
        vm.prank(setter);
        manager.pause();

        vm.prank(nonSetter);
        vm.expectRevert("Lending Manager: Only Setter Use");
        manager.unpause();
    }

    function test_UnpauseRestoresOperations() public {
        vm.prank(setter);
        manager.pause();

        // Confirm paused
        vm.prank(setter);
        vm.expectRevert("Pausable: paused");
        manager.assetsDeposit(address(mockToken), 100, setter);

        // Unpause
        vm.prank(setter);
        manager.unpause();

        // Operations should work again (will revert for other reasons, not Pausable)
        // assetsDeposit will revert with "Lending Manager: Token not licensed" not "Pausable: paused"
        vm.prank(setter);
        vm.expectRevert("Lending Manager: Token not licensed");
        manager.assetsDeposit(address(mockToken), 100, setter);
    }

    function test_LendingVaultsPausability() public {
        lendingVaults vImpl = new lendingVaults();
        bytes memory initData = abi.encodeWithSelector(
            lendingVaults.initialize.selector,
            setter
        );
        ERC1967Proxy vProxy = new ERC1967Proxy(address(vImpl), initData);
        lendingVaults vaults = lendingVaults(payable(address(vProxy)));

        // Setter can pause
        vm.prank(setter);
        vaults.pause();

        // Non-setter cannot unpause
        vm.prank(nonSetter);
        vm.expectRevert("Lending Vault: Only Setter Use");
        vaults.unpause();

        // Setter can unpause
        vm.prank(setter);
        vaults.unpause();
    }
}

// ===========================================================================
//  5.  Access Control Tests
// ===========================================================================

contract AccessControlTest is TestBase {
    address public setter = address(0xA1);
    address public newSetter = address(0xC1);
    address public nonSetter = address(0xB1);
    address public randomUser = address(0xD1);

    // ---- LendingManager access control ----

    function test_LendingManager_OnlySetterCanSetup() public {
        lendingManager impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        lendingManager mgr = lendingManager(address(proxy));

        vm.prank(nonSetter);
        vm.expectRevert("Lending Manager: Only Setter Use");
        mgr.setup(address(0x1), address(0x2), address(0x3), address(0x4), address(0x5));
    }

    function test_LendingManager_TwoStepSetterTransfer() public {
        lendingManager impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        lendingManager mgr = lendingManager(address(proxy));

        // Step 1: setter initiates transfer
        vm.prank(setter);
        mgr.transferSetter(newSetter);

        // Still the old setter
        assertEq(mgr.setter(), setter);

        // Random user cannot accept
        vm.prank(randomUser);
        vm.expectRevert("Lending Manager: Permission FORBIDDEN");
        mgr.acceptSetter(true);

        // Step 2: new setter accepts
        vm.prank(newSetter);
        mgr.acceptSetter(true);
        assertEq(mgr.setter(), newSetter);

        // Old setter can no longer upgrade
        LendingManagerV2 implV2 = new LendingManagerV2();
        vm.prank(setter);
        vm.expectRevert("not setter");
        mgr.upgradeTo(address(implV2));

        // New setter CAN upgrade
        vm.prank(newSetter);
        mgr.upgradeTo(address(implV2));
    }

    function test_LendingManager_SetterTransferReject() public {
        lendingManager impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        lendingManager mgr = lendingManager(address(proxy));

        vm.prank(setter);
        mgr.transferSetter(newSetter);

        // New setter rejects
        vm.prank(newSetter);
        mgr.acceptSetter(false);

        // Original setter remains
        assertEq(mgr.setter(), setter);
    }

    // ---- LendingVaults access control ----

    function test_LendingVaults_TwoStepSetterTransfer() public {
        lendingVaults impl = new lendingVaults();
        bytes memory initData = abi.encodeWithSelector(
            lendingVaults.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        lendingVaults vaults = lendingVaults(payable(address(proxy)));

        vm.prank(setter);
        vaults.transferSetter(newSetter);

        vm.prank(newSetter);
        vaults.acceptSetter(true);

        assertEq(vaults.setter(), newSetter);

        // Old setter cannot upgrade
        LendingVaultsV2 implV2 = new LendingVaultsV2();
        vm.prank(setter);
        vm.expectRevert("not setter");
        vaults.upgradeTo(address(implV2));

        // New setter can
        vm.prank(newSetter);
        vaults.upgradeTo(address(implV2));
    }

    // ---- CoinFactory access control ----

    function test_CoinFactory_TwoStepAdminTransfer() public {
        coinFactory impl = new coinFactory();
        bytes memory initData = abi.encodeWithSelector(
            coinFactory.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        coinFactory factory = coinFactory(address(proxy));

        vm.prank(setter);
        factory.setPA(newSetter);

        vm.prank(newSetter);
        factory.acceptPA(true);

        assertEq(factory.setPermissionAddress(), newSetter);

        // Old admin cannot upgrade
        CoinFactoryV2 implV2 = new CoinFactoryV2();
        vm.prank(setter);
        vm.expectRevert("not admin");
        factory.upgradeTo(address(implV2));

        // New admin can
        vm.prank(newSetter);
        factory.upgradeTo(address(implV2));
    }

    // ---- ZerrowOracle access control ----

    function test_ZerrowOracle_TwoStepSetterTransfer() public {
        zerrowOracleRedstone impl = new zerrowOracleRedstone();
        bytes memory initData = abi.encodeWithSelector(
            zerrowOracleRedstone.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        zerrowOracleRedstone oracle = zerrowOracleRedstone(payable(address(proxy)));

        vm.prank(setter);
        oracle.transferSetter(newSetter);

        vm.prank(newSetter);
        oracle.acceptSetter(true);

        assertEq(oracle.setter(), newSetter);

        // Old setter cannot upgrade
        ZerrowOracleRedstoneV2 implV2 = new ZerrowOracleRedstoneV2();
        vm.prank(setter);
        vm.expectRevert("not setter");
        oracle.upgradeTo(address(implV2));

        // New setter can
        vm.prank(newSetter);
        oracle.upgradeTo(address(implV2));
    }

    // ---- DepositOrLoanCoin access control ----

    function test_DepositOrLoanCoin_SetterAccessControl() public {
        MockLendingManagerForCoin mockManager = new MockLendingManagerForCoin();
        MockReward mockReward = new MockReward();
        MockERC20 mockToken = new MockERC20("Mock", "M", 18);

        depositOrLoanCoin impl = new depositOrLoanCoin();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl));

        bytes memory initData = abi.encodeWithSelector(
            depositOrLoanCoin.initialize.selector,
            "Test",
            "T",
            setter,
            address(mockToken),
            address(mockManager),
            0,
            address(mockReward)
        );
        BeaconProxy bp = new BeaconProxy(address(beacon), initData);
        depositOrLoanCoin coin = depositOrLoanCoin(address(bp));

        // Non-setter cannot call setter-only functions
        vm.prank(nonSetter);
        vm.expectRevert("Deposit Or Loan Coin: Only setter Use");
        coin.mintLockerSetup(true);

        // Setter can
        vm.prank(setter);
        coin.mintLockerSetup(true);
        assertTrue(coin.mintlock());
    }

    function test_DepositOrLoanCoin_TwoStepSetterTransfer() public {
        MockLendingManagerForCoin mockManager = new MockLendingManagerForCoin();
        MockReward mockReward = new MockReward();
        MockERC20 mockToken = new MockERC20("Mock", "M", 18);

        depositOrLoanCoin impl = new depositOrLoanCoin();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl));

        bytes memory initData = abi.encodeWithSelector(
            depositOrLoanCoin.initialize.selector,
            "Test",
            "T",
            setter,
            address(mockToken),
            address(mockManager),
            0,
            address(mockReward)
        );
        BeaconProxy bp = new BeaconProxy(address(beacon), initData);
        depositOrLoanCoin coin = depositOrLoanCoin(address(bp));

        vm.prank(setter);
        coin.transferSetter(newSetter);

        vm.prank(newSetter);
        coin.acceptSetter(true);

        assertEq(coin.setter(), newSetter);

        // Old setter can no longer call setter functions
        vm.prank(setter);
        vm.expectRevert("Deposit Or Loan Coin: Only setter Use");
        coin.mintLockerSetup(true);
    }

    // ---- Upgrade authorization from non-authorized after setter transfer ----

    function test_UpgradeAfterSetterTransfer_LendingManager() public {
        lendingManager impl = new lendingManager();
        bytes memory initData = abi.encodeWithSelector(
            lendingManager.initialize.selector,
            setter
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        lendingManager mgr = lendingManager(address(proxy));

        // Transfer setter
        vm.prank(setter);
        mgr.transferSetter(newSetter);
        vm.prank(newSetter);
        mgr.acceptSetter(true);

        // Upgrade with new setter works
        LendingManagerV2 implV2 = new LendingManagerV2();
        vm.prank(newSetter);
        mgr.upgradeTo(address(implV2));

        // Verify state is intact
        LendingManagerV2 mgrV2 = LendingManagerV2(address(proxy));
        assertEq(mgrV2.setter(), newSetter);
        assertEq(mgrV2.version(), "v2");
    }
}
