// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/TestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lstInterface.sol";
import "../contracts/lendingInterface.sol";
import "../contracts/zerrowOracleRedstone.sol";
import "../contracts/lendingCoreAlgorithm.sol";
import "../contracts/template/depositOrLoanCoin.sol";
import "../contracts/rewardRecordMock.sol";
import "../contracts/test/MockERC20.sol";
import "../contracts/interfaces/iDepositOrLoanCoin.sol";

// ---------------------------------------------------------------------------
// Mock Aggregator (reused from AuditFixVerification)
// ---------------------------------------------------------------------------
contract MockAggregatorRIM {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;

    constructor(int256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function setPrice(int256 price_) external {
        _price = price_;
        _updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) { return _decimals; }
    function description() external pure returns (string memory) { return "Mock"; }
    function version() external pure returns (uint256) { return 1; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }
}

// ===========================================================================
//  FR-M-02: RIM Share-Based Debt Tracking Tests
// ===========================================================================
contract RIMShareTrackingTest is TestBase {
    // ---- Contracts ----
    lendingManager  public manager;
    lendingVaults   public vaults;
    coinFactory     public factory;
    lendingInterface public iface;
    zerrowOracleRedstone public oracle;
    lendingCoreAlgorithm public coreAlgo;
    rewardRecordMock     public reward;
    UpgradeableBeacon    public beacon;

    // ---- Tokens ----
    // tokenA = RIM collateral (ETH-like, 18 dec, $2000)
    // tokenB = borrow asset / riskIsolationModeAcceptAssets (USDC-like, 6 dec, $1)
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    // ---- Oracle feeds ----
    MockAggregatorRIM public feedA;
    MockAggregatorRIM public feedB;

    // ---- Actors ----
    address public setter   = address(this);
    address public user1    = address(0xA1);
    address public user2    = address(0xA2);
    address public liquidator = address(0xA3);

    // ---- Coin addresses ----
    address public depositCoinA;
    address public loanCoinA;
    address public depositCoinB;
    address public loanCoinB;

    // ---- RIM cap (in normalized 18-decimal units) ----
    // 10,000 USDC cap → 10_000e18 normalized
    uint public constant RIM_CAP = 10_000 ether;

    function setUp() public {
        // ---- Tokens ----
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);

        // ---- Oracle feeds ($2000/TKA, $1/TKB) ----
        feedA = new MockAggregatorRIM(2000e8, 8);
        feedB = new MockAggregatorRIM(1e8, 8);

        // ---- Deploy protocol stack ----
        reward = new rewardRecordMock();

        // Oracle (UUPS)
        {
            zerrowOracleRedstone impl = new zerrowOracleRedstone();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(zerrowOracleRedstone.initialize.selector, setter)
            );
            oracle = zerrowOracleRedstone(payable(address(proxy)));
        }
        oracle.setTokenFeed(address(tokenA), address(feedA));
        oracle.setTokenFeed(address(tokenB), address(feedB));

        // LendingManager (UUPS)
        {
            lendingManager impl = new lendingManager();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(lendingManager.initialize.selector, setter)
            );
            manager = lendingManager(address(proxy));
        }

        // LendingVaults (UUPS)
        {
            lendingVaults impl = new lendingVaults();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(lendingVaults.initialize.selector, setter)
            );
            vaults = lendingVaults(payable(address(proxy)));
        }

        // CoinFactory (UUPS)
        {
            coinFactory impl = new coinFactory();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(coinFactory.initialize.selector, setter)
            );
            factory = coinFactory(address(proxy));
        }

        // Beacon for depositOrLoanCoin
        {
            depositOrLoanCoin coinImpl = new depositOrLoanCoin();
            beacon = new UpgradeableBeacon(address(coinImpl));
        }

        // Core algorithm
        coreAlgo = new lendingCoreAlgorithm(address(manager));

        // ---- Wire together ----
        // CRITICAL: riskIsolationModeAcceptAssets = tokenB (the borrow asset)
        manager.setup(
            address(factory),
            address(vaults),
            address(tokenB),       // RIM users borrow tokenB
            address(coreAlgo),
            address(oracle)
        );
        vaults.setManager(address(manager));
        factory.settings(address(manager), address(reward));
        factory.rewardTypeSetup(1, 2);
        factory.setBeacon(address(beacon));

        // Whitelist test contract as interface
        manager.xInterfacesetting(address(this), true);

        // ---- Deploy lendingInterface (UUPS) ----
        {
            lendingInterface impl = new lendingInterface();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    lendingInterface.initialize.selector,
                    address(manager),
                    address(tokenA),  // lstAsset (unused for these tests)
                    address(coreAlgo),
                    address(oracle),
                    address(0xBEEF),  // lstContract placeholder
                    address(tokenA)   // wNative placeholder
                )
            );
            iface = lendingInterface(payable(address(proxy)));
        }

        // ---- Register tokenA: RIM collateral ----
        // maxLendingAmountInRIM = RIM_CAP (10,000 normalized USDC)
        manager.licensedAssetsRegister(
            address(tokenA),
            8000,      // maxLTV (80%)
            500,       // liqPenalty (5%)
            RIM_CAP,   // maxLendingAmountInRIM — THIS makes tokenA a RIM collateral
            7000,      // bestLendingRatio
            1000,      // reserveFactor
            0,         // lendingModeNum
            9500,      // homogeneousModeLTV
            450,       // bestDepositInterestRate
            true       // isNew
        );

        // ---- Register tokenB: normal asset (borrowable in RIM) ----
        manager.licensedAssetsRegister(
            address(tokenB),
            9500,      // maxLTV
            300,       // liqPenalty
            0,         // maxLendingAmountInRIM = 0 (not a RIM collateral)
            7600,      // bestLendingRatio
            1000,      // reserveFactor
            0,         // lendingModeNum
            9700,      // homogeneousModeLTV
            400,       // bestDepositInterestRate
            true
        );

        // ---- Cache coin addresses ----
        address[2] memory pairA = manager.assetsDepositAndLendAddrs(address(tokenA));
        depositCoinA = pairA[0];
        loanCoinA = pairA[1];

        address[2] memory pairB = manager.assetsDepositAndLendAddrs(address(tokenB));
        depositCoinB = pairB[0];
        loanCoinB = pairB[1];

        // ---- Fund accounts ----
        tokenA.mint(address(this), 1_000 ether);
        tokenB.mint(address(this), 1_000_000e6);
        tokenA.mint(liquidator, 100 ether);
        tokenB.mint(liquidator, 100_000e6);

        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);
        vm.prank(liquidator);
        tokenA.approve(address(manager), type(uint256).max);
        vm.prank(liquidator);
        tokenB.approve(address(manager), type(uint256).max);

        // Users approve the test contract (interface)
        vm.prank(user1);
        manager.setInterfaceApproval(true);
        vm.prank(user2);
        manager.setInterfaceApproval(true);

        manager.setFlashLoanFeesAddress(address(0xFEE1));

        // ---- Seed tokenB liquidity (mode-0 user deposits tokenB) ----
        // user2 provides 12,000 USDC — small pool forces high utilization
        // when user1 borrows ~9,500, giving ~79% utilization → meaningful interest
        manager.assetsDeposit(address(tokenB), 12_000e6, user2);
    }

    /// @dev Helper: warp forward and refresh oracle feed timestamps
    ///      so prices don't go stale.
    function _warpAndRefreshOracle(uint duration) internal {
        vm.warp(block.timestamp + duration);
        feedA.setUpdatedAt(block.timestamp);
        feedB.setUpdatedAt(block.timestamp);
    }

    // =====================================================================
    //  Helper: put user into RIM mode 1 with tokenA as collateral
    // =====================================================================
    function _enterRIMMode(address user) internal {
        manager.userModeSetting(1, address(tokenA), user);
    }

    // =====================================================================
    //  Test 1: Borrow in RIM mode stores OQC shares, not balanceOf values
    // =====================================================================

    /// @notice After a RIM borrow, the RIM mapping should store the user's
    ///         raw OQC shares, matching depositOrLoanCoin.userOQCAmount.
    ///         At par (coinValue = 1e18), shares == normalized value.
    ///         After interest accrues (coinValue > 1e18), shares < value.
    function test_RIM_BorrowStoresSharesNotValues() public {
        // Enter RIM mode for user1
        _enterRIMMode(user1);

        // Deposit collateral: 10 ETH ($20,000)
        manager.assetsDeposit(address(tokenA), 10 ether, user1);

        // Borrow 5,000 USDC (well within 10k cap and HF)
        uint borrowAmount = 5_000e6;
        manager.lendAsset(address(tokenB), borrowAmount, user1);

        // The mapping should store the user's OQC shares
        uint rimMapped = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint oqcShares = iDepositOrLoanCoin(loanCoinB).userOQCAmount(user1);
        uint balance    = IERC20(loanCoinB).balanceOf(user1);

        // At par (fresh market, coinValue = 1e18), shares == value
        assertEq(rimMapped, oqcShares, "RIM mapping must equal OQC shares");
        // Sanity: balanceOf should approximately equal the normalized borrow
        assertGt(balance, 0, "User should have a loan balance");
    }

    /// @notice After interest accrues, the stored shares diverge from
    ///         balanceOf. This verifies the mapping tracks shares, not value.
    function test_RIM_SharesDivergeFromValueAfterInterest() public {
        _enterRIMMode(user1);
        manager.assetsDeposit(address(tokenA), 10 ether, user1);
        manager.lendAsset(address(tokenB), 5_000e6, user1);

        // Record initial state
        uint sharesBefore = iDepositOrLoanCoin(loanCoinB).userOQCAmount(user1);
        uint balanceBefore = IERC20(loanCoinB).balanceOf(user1);

        // At par, shares == balance
        assertEq(sharesBefore, balanceBefore, "At par: shares should equal balance");

        // Warp forward 180 days — interest accrues, coinValue grows
        _warpAndRefreshOracle(180 days);

        // OQC shares are unchanged (raw, interest-independent)
        uint sharesAfter = iDepositOrLoanCoin(loanCoinB).userOQCAmount(user1);
        assertEq(sharesAfter, sharesBefore, "OQC shares must not change with time");

        // balanceOf grows because coinValue grew
        uint balanceAfter = IERC20(loanCoinB).balanceOf(user1);
        assertGt(balanceAfter, balanceBefore, "Balance must grow with interest");

        // The mapping still stores shares (not the grown balance)
        uint rimMapped = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        assertEq(rimMapped, sharesAfter, "RIM mapping must track shares, not value");
        assertTrue(rimMapped < balanceAfter, "Shares must be less than value after interest");
    }

    // =====================================================================
    //  Test 2: Dormant borrower's interest is captured in RIM cap check
    // =====================================================================

    /// @notice This is the core FR-M-02 bug fix test. When a borrower goes
    ///         dormant and interest accrues, the RIM cap check must reflect
    ///         the grown debt. A new borrow that would fit under stale
    ///         value-based accounting should now correctly revert.
    function test_RIM_DormantBorrowerCapReflectsInterest() public {
        _enterRIMMode(user1);
        manager.assetsDeposit(address(tokenA), 10 ether, user1);

        // Borrow 9,500 of 10,000 cap (95% utilization of cap)
        // With 12,000 USDC deposited and 9,500 borrowed → ~79% utilization
        // This gives a meaningful interest rate
        manager.lendAsset(address(tokenB), 9_500e6, user1);

        // Sanity: coinValue is 1e18 at this point
        uint[2] memory cv = manager.getCoinValues(address(tokenB));
        assertEq(cv[1], 1 ether, "Lending coinValue should be 1e18 at start");

        // Warp forward 365 days — interest causes coinValue to grow
        // Refresh oracle so prices don't stale
        _warpAndRefreshOracle(365 days);

        // Verify coinValue has grown above par
        cv = manager.getCoinValues(address(tokenB));
        assertGt(cv[1], 1 ether, "Lending coinValue must grow after 365 days of utilization");

        // Compute what the cap check now sees:
        // totalShares * currentCoinValue / 1e18 should exceed the cap
        uint totalRIMShares = manager.riskIsolationModeLendingNetAmount(address(tokenA));
        uint effectiveDebt = totalRIMShares * cv[1] / 1 ether;

        // The effective debt should have grown past the 10,000 cap
        // (9,500 shares * coinValue > 10,000 when coinValue > ~1.0526)
        assertGt(effectiveDebt, RIM_CAP, "Effective RIM debt must exceed cap after interest");

        // Now try to borrow even 1 more unit — should revert
        // (This would have PASSED under the old value-based accounting)
        vm.expectRevert(abi.encodeWithSelector(lendingManager.RIMBorrowLimitExceeded.selector));
        manager.lendAsset(address(tokenB), 1e6, user1);
    }

    // =====================================================================
    //  Test 3: Repay in RIM mode correctly decrements share counters
    // =====================================================================

    /// @notice After a repay, both user and global RIM counters should
    ///         reflect the actual OQC share state post-burn.
    function test_RIM_RepayDecrementsShareCounters() public {
        _enterRIMMode(user1);
        manager.assetsDeposit(address(tokenA), 10 ether, user1);
        manager.lendAsset(address(tokenB), 5_000e6, user1);

        uint sharesBefore = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint globalBefore = manager.riskIsolationModeLendingNetAmount(address(tokenA));
        assertGt(sharesBefore, 0, "User should have RIM shares after borrow");
        assertGt(globalBefore, 0, "Global RIM counter should be non-zero");

        // Repay 2,000 USDC
        // Need to give user1 tokens to repay (they received raw tokenB from borrow)
        // Actually repayLoan does safeTransferFrom(msg.sender, vault, amount)
        // msg.sender is the test contract (interface), so test contract needs tokenB
        manager.repayLoan(address(tokenB), 2_000e6, user1);

        uint sharesAfter = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint globalAfter = manager.riskIsolationModeLendingNetAmount(address(tokenA));
        uint oqcAfter = iDepositOrLoanCoin(loanCoinB).userOQCAmount(user1);

        // Shares should have decreased
        assertLt(sharesAfter, sharesBefore, "User RIM shares must decrease after repay");
        assertLt(globalAfter, globalBefore, "Global RIM counter must decrease after repay");

        // And the decrement should match OQC shares closely
        // (repay goes through _updateRIMAccounting which predicts shares)
        // Allow ±1 for rounding
        uint diff = sharesAfter > oqcAfter ? sharesAfter - oqcAfter : oqcAfter - sharesAfter;
        assertTrue(diff <= 1, "RIM mapping must match OQC shares within 1 wei");
    }

    // =====================================================================
    //  Test 4: Liquidation syncs RIM counters via _decrementRIMDebt
    // =====================================================================

    /// @notice After a liquidation, _decrementRIMDebt reads the post-burn
    ///         userOQCAmount and syncs both user and global RIM mappings.
    function test_RIM_LiquidationSyncsSharesCorrectly() public {
        _enterRIMMode(user1);
        manager.assetsDeposit(address(tokenA), 10 ether, user1);

        // Borrow enough to be close to liquidation threshold
        // At $2000/ETH: collateral = $20,000, maxLTV=80% → max borrow ~ $16,000
        // With HF floor of 1.2: max borrow = $16,000/1.2 = $13,333
        // Borrow $9,000 to stay safe initially
        manager.lendAsset(address(tokenB), 9_000e6, user1);

        uint sharesBefore = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint globalBefore = manager.riskIsolationModeLendingNetAmount(address(tokenA));
        assertGt(sharesBefore, 0, "Pre-liq: user should have RIM shares");

        // Drop tokenA price to make user1 liquidatable
        // At $2000: HF = ($20,000 * 0.8) / $9,000 = 1.78 (safe)
        // At $500:  HF = ($5,000 * 0.8) / $9,000 = 0.44 (underwater)
        feedA.setPrice(500e8);

        // Liquidate: repay ~50% of debt (close factor) using tokenB
        // Liquidator pays raw tokenB, seizes tokenA collateral.
        // Borrowed 9,000 USDC → repay 4,500 USDC raw (50% close factor)
        uint liquidateAmount = 4_500e6;

        // Liquidator needs to approve and call directly (not through interface)
        vm.prank(liquidator);
        manager.tokenLiquidate(
            user1,
            address(tokenB),   // debt token to repay
            liquidateAmount,
            address(tokenA)    // collateral to seize
        );

        // After liquidation, check RIM mapping sync
        uint sharesAfter = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint globalAfter = manager.riskIsolationModeLendingNetAmount(address(tokenA));
        uint oqcAfter = iDepositOrLoanCoin(loanCoinB).userOQCAmount(user1);

        // Shares should have decreased
        assertLt(sharesAfter, sharesBefore, "Post-liq: user RIM shares must decrease");
        assertLt(globalAfter, globalBefore, "Post-liq: global RIM counter must decrease");

        // _decrementRIMDebt reads actual post-burn OQC, so mapping == OQC exactly
        assertEq(sharesAfter, oqcAfter, "Post-liq: RIM mapping must exactly equal OQC shares");

        // Global counter should also be consistent
        // (single user, so global == user)
        assertEq(globalAfter, sharesAfter, "Post-liq: global counter must match user counter");
    }

    // =====================================================================
    //  Test 5: View functions convert shares to value
    // =====================================================================

    /// @notice The lendingInterface view functions should return value-
    ///         denominated amounts (shares × coinValue / 1e18), not raw shares.
    function test_RIM_ViewFunctionsReturnValues() public {
        _enterRIMMode(user1);
        manager.assetsDeposit(address(tokenA), 10 ether, user1);
        manager.lendAsset(address(tokenB), 5_000e6, user1);

        // Warp forward so coinValue diverges from 1e18
        _warpAndRefreshOracle(180 days);

        uint[2] memory cv = manager.getCoinValues(address(tokenB));
        assertGt(cv[1], 1 ether, "CoinValue should have grown");

        // Raw mapping (manager) stores shares
        uint rawShares = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));

        // Interface view should return value = shares * coinValue / 1e18
        uint ifaceValue = iface.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint expectedValue = rawShares * cv[1] / 1 ether;

        assertEq(ifaceValue, expectedValue, "Interface must return shares * coinValue / 1e18");
        assertGt(ifaceValue, rawShares, "View value must exceed raw shares after interest");
    }

    /// @notice Global RIM counter view should also convert to value.
    function test_RIM_GlobalViewConvertsToValue() public {
        _enterRIMMode(user1);
        manager.assetsDeposit(address(tokenA), 10 ether, user1);
        manager.lendAsset(address(tokenB), 5_000e6, user1);

        vm.warp(block.timestamp + 180 days);

        uint[2] memory cv = manager.getCoinValues(address(tokenB));
        uint rawGlobalShares = manager.riskIsolationModeLendingNetAmount(address(tokenA));
        uint ifaceGlobalValue = iface.riskIsolationModeLendingNetAmount(address(tokenA));
        uint expectedValue = rawGlobalShares * cv[1] / 1 ether;

        assertEq(ifaceGlobalValue, expectedValue, "Global view must convert shares to value");
        assertGt(ifaceGlobalValue, rawGlobalShares, "Global view value must exceed raw shares");
    }

}

// ===========================================================================
//  Separate test with clean multi-user RIM setup
// ===========================================================================
contract RIMMultiUserTest is TestBase {
    lendingManager  public manager;
    lendingVaults   public vaults;
    coinFactory     public factory;
    zerrowOracleRedstone public oracle;
    lendingCoreAlgorithm public coreAlgo;
    rewardRecordMock     public reward;
    UpgradeableBeacon    public beacon;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockAggregatorRIM public feedA;
    MockAggregatorRIM public feedB;

    address public setter     = address(this);
    address public user1      = address(0xA1);
    address public user2      = address(0xA2);
    address public liqProvider = address(0xA4);

    address public depositCoinA;
    address public loanCoinA;
    address public depositCoinB;
    address public loanCoinB;

    uint public constant RIM_CAP = 10_000 ether;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);
        feedA = new MockAggregatorRIM(2000e8, 8);
        feedB = new MockAggregatorRIM(1e8, 8);
        reward = new rewardRecordMock();

        {
            zerrowOracleRedstone impl = new zerrowOracleRedstone();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(zerrowOracleRedstone.initialize.selector, setter)
            );
            oracle = zerrowOracleRedstone(payable(address(proxy)));
        }
        oracle.setTokenFeed(address(tokenA), address(feedA));
        oracle.setTokenFeed(address(tokenB), address(feedB));

        {
            lendingManager impl = new lendingManager();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(lendingManager.initialize.selector, setter)
            );
            manager = lendingManager(address(proxy));
        }
        {
            lendingVaults impl = new lendingVaults();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(lendingVaults.initialize.selector, setter)
            );
            vaults = lendingVaults(payable(address(proxy)));
        }
        {
            coinFactory impl = new coinFactory();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(coinFactory.initialize.selector, setter)
            );
            factory = coinFactory(address(proxy));
        }
        {
            depositOrLoanCoin coinImpl = new depositOrLoanCoin();
            beacon = new UpgradeableBeacon(address(coinImpl));
        }
        coreAlgo = new lendingCoreAlgorithm(address(manager));

        manager.setup(address(factory), address(vaults), address(tokenB), address(coreAlgo), address(oracle));
        vaults.setManager(address(manager));
        factory.settings(address(manager), address(reward));
        factory.rewardTypeSetup(1, 2);
        factory.setBeacon(address(beacon));
        manager.xInterfacesetting(address(this), true);

        manager.licensedAssetsRegister(address(tokenA), 8000, 500, RIM_CAP, 7000, 1000, 0, 9500, 450, true);
        manager.licensedAssetsRegister(address(tokenB), 9500, 300, 0, 7600, 1000, 0, 9700, 400, true);

        address[2] memory pairA = manager.assetsDepositAndLendAddrs(address(tokenA));
        depositCoinA = pairA[0]; loanCoinA = pairA[1];
        address[2] memory pairB = manager.assetsDepositAndLendAddrs(address(tokenB));
        depositCoinB = pairB[0]; loanCoinB = pairB[1];

        tokenA.mint(address(this), 1_000 ether);
        tokenB.mint(address(this), 1_000_000e6);
        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);

        vm.prank(user1); manager.setInterfaceApproval(true);
        vm.prank(user2); manager.setInterfaceApproval(true);
        vm.prank(liqProvider); manager.setInterfaceApproval(true);

        manager.setFlashLoanFeesAddress(address(0xFEE1));

        // liqProvider (mode 0) seeds tokenB liquidity — not user1 or user2
        // Smaller pool → higher utilization → meaningful interest accrual
        manager.assetsDeposit(address(tokenB), 12_000e6, liqProvider);
    }

    /// @dev Helper: warp forward and refresh oracle feed timestamps
    function _warpAndRefreshOracle(uint duration) internal {
        vm.warp(block.timestamp + duration);
        feedA.setUpdatedAt(block.timestamp);
        feedB.setUpdatedAt(block.timestamp);
    }

    /// @notice Two RIM users borrow. Global counter = sum of individual shares.
    function test_RIM_MultipleUsersGlobalTracking() public {
        // Both users enter RIM mode
        manager.userModeSetting(1, address(tokenA), user1);
        manager.userModeSetting(1, address(tokenA), user2);

        // user1: deposit 10 ETH, borrow 3000 USDC
        manager.assetsDeposit(address(tokenA), 10 ether, user1);
        manager.lendAsset(address(tokenB), 3_000e6, user1);

        // user2: deposit 5 ETH, borrow 2000 USDC
        manager.assetsDeposit(address(tokenA), 5 ether, user2);
        manager.lendAsset(address(tokenB), 2_000e6, user2);

        uint user1Shares = manager.userRIMAssetsLendingNetAmount(user1, address(tokenB));
        uint user2Shares = manager.userRIMAssetsLendingNetAmount(user2, address(tokenB));
        uint globalShares = manager.riskIsolationModeLendingNetAmount(address(tokenA));

        // Global counter must equal sum of user counters
        assertEq(globalShares, user1Shares + user2Shares,
            "Global RIM shares must equal sum of user shares");

        // Each user's mapping must match their OQC shares
        assertEq(user1Shares, iDepositOrLoanCoin(loanCoinB).userOQCAmount(user1),
            "User1 RIM mapping must match OQC shares");
        assertEq(user2Shares, iDepositOrLoanCoin(loanCoinB).userOQCAmount(user2),
            "User2 RIM mapping must match OQC shares");
    }

    /// @notice Two users borrow near the cap. After dormant interest,
    ///         a third borrow is blocked by the grown total debt.
    function test_RIM_MultiUserCapBlocksAfterDormantInterest() public {
        manager.userModeSetting(1, address(tokenA), user1);
        manager.userModeSetting(1, address(tokenA), user2);

        // user1: deposit 10 ETH, borrow 5000 USDC (50% of cap)
        manager.assetsDeposit(address(tokenA), 10 ether, user1);
        manager.lendAsset(address(tokenB), 5_000e6, user1);

        // user2: deposit 10 ETH, borrow 4500 USDC (45% of cap)
        // Total: 9500/10000 = 95% of cap
        manager.assetsDeposit(address(tokenA), 10 ether, user2);
        manager.lendAsset(address(tokenB), 4_500e6, user2);

        // Warp forward — interest pushes effective debt above cap
        _warpAndRefreshOracle(365 days);

        uint[2] memory cv = manager.getCoinValues(address(tokenB));
        assertGt(cv[1], 1 ether, "CoinValue must grow with utilization");

        // Any new borrow should revert
        vm.expectRevert(abi.encodeWithSelector(lendingManager.RIMBorrowLimitExceeded.selector));
        manager.lendAsset(address(tokenB), 1e6, user2);
    }
}
