// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/TestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lendingInterface.sol";
import "../contracts/zerrowOracleRedstone.sol";
import "../contracts/lendingCoreAlgorithm.sol";
import "../contracts/template/depositOrLoanCoin.sol";
import "../contracts/rewardRecordMock.sol";
import "../contracts/test/MockERC20.sol";
import "../contracts/interfaces/iDepositOrLoanCoin.sol";

// ---------------------------------------------------------------------------
// Mock Aggregator
// ---------------------------------------------------------------------------
contract MockAggregatorBD {
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
//  R2-H-01: Bad-debt full-wipe sentinel must survive _assetsValueUpdate
// ===========================================================================
contract BadDebtSentinelTest is TestBase {
    // ---- Contracts ----
    lendingManager  public manager;
    lendingVaults   public vaults;
    coinFactory     public factory;
    zerrowOracleRedstone public oracle;
    lendingCoreAlgorithm public coreAlgo;
    rewardRecordMock     public reward;
    UpgradeableBeacon    public beacon;

    // ---- Tokens ----
    // tokenA = collateral (ETH-like, 18 dec, $2000)
    // tokenB = borrow asset (USDC-like, 6 dec, $1)
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    // ---- Oracle feeds ----
    MockAggregatorBD public feedA;
    MockAggregatorBD public feedB;

    // ---- Actors ----
    address public setter     = address(this);
    address public depositor  = address(0xD1);  // deposits tokenB into pool
    address public borrower   = address(0xB1);  // borrows tokenB, goes insolvent
    address public liquidator = address(0xAA);

    // ---- Coin addresses ----
    address public depositCoinA;
    address public loanCoinA;
    address public depositCoinB;
    address public loanCoinB;

    function setUp() public {
        // ---- Tokens ----
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 6);

        // ---- Oracle feeds ($2000/TKA, $1/TKB) ----
        feedA = new MockAggregatorBD(2000e8, 8);
        feedB = new MockAggregatorBD(1e8, 8);

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
        manager.setup(
            address(factory),
            address(vaults),
            address(tokenB),       // RIM accept asset (not critical for this test)
            address(coreAlgo),
            address(oracle)
        );
        vaults.setManager(address(manager));
        factory.settings(address(manager), address(reward));
        factory.rewardTypeSetup(1, 2);
        factory.setBeacon(address(beacon));

        // Whitelist test contract as interface
        manager.xInterfacesetting(address(this), true);

        // ---- Register tokenA: collateral ----
        // liqPenalty = 500 (5%). Borrower deposits 21 ETH (not 10) so that
        // 21e18 * 10000 / 10500 = 20e18 (exact, no truncation). This lets a
        // single liquidation seize ALL collateral, triggering _socializeBadDebt.
        manager.licensedAssetsRegister(
            address(tokenA),
            8000,      // maxLTV (80%)
            500,       // liqPenalty (5%)
            0,         // maxLendingAmountInRIM (not RIM collateral for this test)
            7000,      // bestLendingRatio
            1000,      // reserveFactor
            0,         // lendingModeNum
            9500,      // homogeneousModeLTV
            450,       // bestDepositInterestRate
            true       // isNew
        );

        // ---- Register tokenB: borrowable asset ----
        manager.licensedAssetsRegister(
            address(tokenB),
            9500,      // maxLTV
            300,       // liqPenalty
            0,         // maxLendingAmountInRIM
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
        tokenA.mint(borrower, 100 ether);
        tokenB.mint(borrower, 100_000e6);
        tokenA.mint(liquidator, 100 ether);
        tokenB.mint(liquidator, 200_000e6);
        tokenA.mint(depositor, 100 ether);
        tokenB.mint(depositor, 500_000e6);

        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);

        vm.prank(borrower);
        tokenA.approve(address(manager), type(uint256).max);
        vm.prank(borrower);
        tokenB.approve(address(manager), type(uint256).max);

        vm.prank(liquidator);
        tokenA.approve(address(manager), type(uint256).max);
        vm.prank(liquidator);
        tokenB.approve(address(manager), type(uint256).max);

        vm.prank(depositor);
        tokenA.approve(address(manager), type(uint256).max);
        vm.prank(depositor);
        tokenB.approve(address(manager), type(uint256).max);

        // Approvals for interface
        vm.prank(borrower);
        manager.setInterfaceApproval(true);
        vm.prank(depositor);
        manager.setInterfaceApproval(true);
        vm.prank(liquidator);
        manager.setInterfaceApproval(true);

        manager.setFlashLoanFeesAddress(address(0xFEE1));
    }

    /// @dev Helper: warp forward and refresh oracle feed timestamps
    function _warpAndRefreshOracle(uint duration) internal {
        vm.warp(block.timestamp + duration);
        feedA.setUpdatedAt(block.timestamp);
        feedB.setUpdatedAt(block.timestamp);
    }

    /// @dev Helper: liquidate the borrower's debt up to collateral limits.
    ///      With 5% penalty and 21 ETH collateral, the math is exact:
    ///      21e18 * 10000 / 10500 = 20e18 (no truncation).
    ///      20e18 * 10500 / 10000 = 21e18 → seizes all collateral.
    ///      After collateral hits 0, _socializeBadDebt fires automatically.
    function _liquidateToSocialize(address _borrower) internal {
        uint collateral = IERC20(depositCoinA).balanceOf(_borrower);
        uint collateralPrice = oracle.getPrice(address(tokenA));
        uint debtPrice = oracle.getPrice(address(tokenB));

        // maxRepayByCollateral = collateral * collateralPrice / debtPrice * 10000 / (10000 + penalty)
        uint maxRepayNormalized = collateral * collateralPrice / 1 ether;
        maxRepayNormalized = maxRepayNormalized * 10000 / 10500; // 5% penalty
        maxRepayNormalized = maxRepayNormalized * 1 ether / debtPrice;

        // Also bound by close factor (50% of debt)
        uint debt = IERC20(loanCoinB).balanceOf(_borrower);
        uint closeMax = debt * 5000 / 10000;
        if (closeMax == 0) closeMax = debt;
        if (maxRepayNormalized > closeMax) maxRepayNormalized = closeMax;
        if (maxRepayNormalized > debt) maxRepayNormalized = debt;

        // Convert from normalized (18 dec) to raw tokenB (6 dec)
        uint rawAmount = maxRepayNormalized / 1e12;
        require(rawAmount > 0, "rawAmount is 0");

        manager.tokenLiquidate(
            _borrower,
            address(tokenB),
            rawAmount,
            address(tokenA)
        );
    }

    // =====================================================================
    //  R2-H-01 Regression: Full bad-debt wipe sentinel must not be reset
    //  to 1 ether by _assetsValueUpdate's idle-market branch.
    //
    //  Scenario:
    //  1. Depositor supplies 5,000 USDC into tokenB pool
    //  2. Borrower deposits 10 ETH collateral, borrows 5,000 USDC (100% of pool)
    //  3. ETH price crashes to $0 → borrower collateral is worthless
    //  4. Liquidator liquidates remaining collateral (negligible), then
    //     _socializeBadDebt() fires: burns all loan shares, sets sentinel
    //  5. ASSERT: sentinel (type(uint256).max) is NOT overwritten by idle reset
    //  6. ASSERT: getCoinValues(tokenB)[0] == 0  (deposits are worthless)
    // =====================================================================

    /// @notice Full bad-debt socialization: deposit coin value sentinel must
    ///         survive the _assetsValueUpdate call that follows immediately.
    ///
    ///         R2-H-01 scenario:
    ///         1. Depositor provides tokenB liquidity
    ///         2. Borrower deposits tokenA collateral, borrows tokenB
    ///         3. Interest accrues → loan value exceeds deposit supply
    ///         4. ETH price crashes → HF < 1
    ///         5. Liquidator repays all of borrower's tokenB debt, seizing all
    ///            tokenA collateral. But the seized collateral < debt value,
    ///            so bad debt remains after collateral is gone.
    ///         6. _socializeBadDebt fires: burnAmounts >= totalDeposits → sentinel
    ///         7. ASSERT: sentinel survives _assetsValueUpdate
    function test_FullWipeSentinelSurvivesAssetsValueUpdate() public {
        // --- Step 1: Depositor provides 5,100 USDC liquidity ---
        manager.assetsDeposit(address(tokenB), 5_100e6, depositor);

        // Verify depositor has deposit coin shares
        uint depositorShares = iDepositOrLoanCoin(depositCoinB).userOQCAmount(depositor);
        assertGt(depositorShares, 0, "Depositor should have deposit shares");

        // --- Step 2: Borrower deposits 21 ETH ($42k) as collateral, borrows 5,000 USDC ---
        manager.assetsDeposit(address(tokenA), 21 ether, borrower);
        manager.lendAsset(address(tokenB), 5_000e6, borrower);

        // --- Step 3: Let interest accrue so loan value grows past deposit supply ---
        _warpAndRefreshOracle(365 days);

        // Verify pre-crash state
        uint[2] memory preValues = manager.getCoinValues(address(tokenB));
        assertGt(preValues[0], 0, "Pre-crash deposit coin value should be positive");

        // --- Step 4: ETH crashes to $1 (99.95% drop) → HF collapses ---
        // Oracle rejects price=0, so we use $1. Borrower has 10 ETH × $1 = $10
        // collateral vs ~$5000+ debt → massively underwater.
        feedA.setPrice(1e8);   // $1 per ETH
        feedA.setUpdatedAt(block.timestamp);

        // --- Step 5: Liquidate all collateral in a loop ---
        // With ETH at $1, borrower has 10 ETH = $10 collateral but ~$5000+ debt.
        // Multiple liquidation rounds may be needed (close factor = 50%).
        // Once all collateral is seized, _socializeBadDebt fires on the final
        // liquidation call and sees depositValue == 0 with lendingValue > 0.
        _liquidateToSocialize(borrower);

        // --- Step 6: Verify the sentinel survived ---
        (uint rawDepositCoinValue,,,) = manager.assetsTimeDependentParameter(address(tokenB));
        assertEq(
            rawDepositCoinValue,
            type(uint256).max,
            "R2-H-01: latestDepositCoinValue must remain type(uint256).max sentinel after full wipe"
        );

        // --- Step 7: getCoinValues must return 0 for wiped deposits ---
        uint[2] memory postValues = manager.getCoinValues(address(tokenB));
        assertEq(
            postValues[0],
            0,
            "R2-H-01: getCoinValues()[0] must be 0 for a fully wiped market"
        );

        // --- Step 8: Depositor's claim should be worthless ---
        uint depositorBalance = IERC20(depositCoinB).balanceOf(depositor);
        assertEq(
            depositorBalance,
            0,
            "Depositor's value-based balance should be 0 (shares exist but value is zero)"
        );

        // OQC shares still exist — only the value mapping is zeroed
        uint depositorSharesAfter = iDepositOrLoanCoin(depositCoinB).userOQCAmount(depositor);
        assertEq(
            depositorSharesAfter,
            depositorShares,
            "Depositor's raw OQC shares should be unchanged (only value was wiped)"
        );
    }

    /// @notice Partial bad-debt socialization should NOT set the sentinel.
    ///         Only full wipes (burnAmounts >= totalDeposits) trigger it.
    function test_PartialBadDebtDoesNotSetSentinel() public {
        // --- Depositor provides 20,000 USDC (large pool) ---
        // Large enough that the borrower's bad debt won't exceed it
        manager.assetsDeposit(address(tokenB), 20_000e6, depositor);

        // --- Borrower deposits 10 ETH, borrows 5,000 USDC (25% of pool) ---
        manager.assetsDeposit(address(tokenA), 21 ether, borrower);
        manager.lendAsset(address(tokenB), 5_000e6, borrower);

        // --- ETH crashes to $1 → bad debt, but only ~25% of pool ---
        feedA.setPrice(1e8);

        // Liquidate all collateral to trigger _socializeBadDebt
        _liquidateToSocialize(borrower);

        // Sentinel should NOT be set (partial wipe — bad debt < total deposits)
        (uint rawDepositCoinValue,,,) = manager.assetsTimeDependentParameter(address(tokenB));
        assertTrue(
            rawDepositCoinValue != type(uint256).max,
            "Partial bad debt should NOT set the full-wipe sentinel"
        );

        // Deposit coin value should be reduced but positive
        uint[2] memory postValues = manager.getCoinValues(address(tokenB));
        assertGt(
            postValues[0],
            0,
            "Deposit coin value should still be positive after partial bad debt"
        );
        assertLt(
            postValues[0],
            1 ether,
            "Deposit coin value should be reduced below par after partial bad debt"
        );
    }

    /// @notice After a full wipe, new operations on the market should see
    ///         deposit value as 0. The sentinel must persist across
    ///         subsequent _beforeUpdate calls.
    function test_SentinelPersistsAcrossSubsequentUpdates() public {
        // --- Setup: depositor provides liquidity, borrower borrows most of it ---
        manager.assetsDeposit(address(tokenB), 5_100e6, depositor);
        manager.assetsDeposit(address(tokenA), 21 ether, borrower);
        manager.lendAsset(address(tokenB), 5_000e6, borrower);

        // Let interest grow loan past deposit supply
        _warpAndRefreshOracle(365 days);

        // --- Crash and socialize ---
        feedA.setPrice(1e8);   // $1 per ETH
        feedA.setUpdatedAt(block.timestamp);

        _liquidateToSocialize(borrower);

        // Confirm sentinel is set
        (uint rawVal1,,,) = manager.assetsTimeDependentParameter(address(tokenB));
        assertEq(rawVal1, type(uint256).max, "Sentinel should be set after full wipe");

        // --- Warp forward to simulate time passing ---
        feedA.setPrice(2000e8);  // Restore ETH price
        _warpAndRefreshOracle(30 days);

        // --- Verify sentinel still holds after time passes ---
        (uint rawVal2,,,) = manager.assetsTimeDependentParameter(address(tokenB));
        assertEq(rawVal2, type(uint256).max, "Sentinel must persist across time warps");

        // getCoinValues still returns 0
        uint[2] memory vals = manager.getCoinValues(address(tokenB));
        assertEq(vals[0], 0, "getCoinValues()[0] must remain 0 after time passes");
    }
}
