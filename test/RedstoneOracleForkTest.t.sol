// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/TestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "../contracts/zerrowOracleRedstone.sol";
import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/coinFactory.sol";
import "../contracts/lendingCoreAlgorithm.sol";
import "../contracts/template/depositOrLoanCoin.sol";
import "../contracts/rewardRecordMock.sol";
import "../contracts/test/MockERC20.sol";
import "../contracts/interfaces/iDepositOrLoanCoin.sol";

// ==========================================================================
//  Fork tests against live Redstone price feeds on 0G Galileo testnet
//
//  Run with:
//    forge test --match-contract RedstoneOracle -vvv \
//      --fork-url <0G_TESTNET_RPC>
// ==========================================================================

contract RedstoneOracleForkTest is TestBase {
    // ── Redstone feed addresses on 0G Galileo testnet ──
    address constant FEED_ETH  = 0x6f57Ff507735BcD3d86af83aF77ABD10395b2904;
    address constant FEED_USDT = 0xED2B1ca5D7E246f615c2291De309643D41FeC97e;
    address constant FEED_USDC = 0xc44be6D00307c3565FDf753e852Fc003036cBc13;
    address constant FEED_WBTC = 0x22d47686b3AEC9068768f84EFD8Ce2637a347B0A;

    // ── Protocol contracts ──
    zerrowOracleRedstone public oracle;
    lendingManager public manager;
    lendingVaults public vaults;
    coinFactory public factory;
    lendingCoreAlgorithm public core;
    rewardRecordMock public reward;

    // ── Test tokens (minted freely, priced via Redstone feeds) ──
    MockERC20 public tokenETH;
    MockERC20 public tokenUSDT;
    MockERC20 public tokenWBTC;

    // ── Actors ──
    address setter;
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address liquidator = address(0x11CC);

    // ── Deposit/Loan coins ──
    address depositCoinETH;
    address loanCoinETH;
    address depositCoinUSDT;
    address loanCoinUSDT;

    function setUp() public {
        setter = address(this);

        // ── 1. Deploy mock ERC20 tokens ──
        tokenETH  = new MockERC20("Mock ETH",  "mETH",  18);
        tokenUSDT = new MockERC20("Mock USDT", "mUSDT", 6);
        tokenWBTC = new MockERC20("Mock WBTC", "mWBTC", 8);

        // ── 2. Deploy Oracle (UUPS proxy) ──
        zerrowOracleRedstone oracleImpl = new zerrowOracleRedstone();
        ERC1967Proxy oracleProxy = new ERC1967Proxy(
            address(oracleImpl),
            abi.encodeWithSelector(zerrowOracleRedstone.initialize.selector, setter)
        );
        oracle = zerrowOracleRedstone(payable(address(oracleProxy)));

        // Wire feeds: map our mock tokens to real Redstone price feeds
        oracle.setTokenFeed(address(tokenETH),  FEED_ETH);
        oracle.setTokenFeed(address(tokenUSDT), FEED_USDT);
        oracle.setTokenFeed(address(tokenWBTC), FEED_WBTC);

        // ── 3. Deploy Reward mock ──
        reward = new rewardRecordMock();

        // ── 4. Deploy Lending Manager (UUPS proxy) ──
        lendingManager managerImpl = new lendingManager();
        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            abi.encodeWithSelector(lendingManager.initialize.selector, setter)
        );
        manager = lendingManager(address(managerProxy));

        // ── 5. Deploy Lending Vaults (UUPS proxy) ──
        lendingVaults vaultsImpl = new lendingVaults();
        ERC1967Proxy vaultsProxy = new ERC1967Proxy(
            address(vaultsImpl),
            abi.encodeWithSelector(lendingVaults.initialize.selector, setter)
        );
        vaults = lendingVaults(payable(address(vaultsProxy)));
        vaults.setManager(address(manager));

        // ── 6. Deploy Coin Factory (UUPS proxy) + Beacon ──
        coinFactory factoryImpl = new coinFactory();
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeWithSelector(coinFactory.initialize.selector, setter)
        );
        factory = coinFactory(address(factoryProxy));

        depositOrLoanCoin coinImpl = new depositOrLoanCoin();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(coinImpl));
        factory.setBeacon(address(beacon));
        factory.settings(address(manager), address(reward));
        factory.rewardTypeSetup(1, 2);

        // ── 7. Deploy Core Algorithm ──
        core = new lendingCoreAlgorithm(address(manager));

        // ── 8. Wire everything ──
        manager.setup(
            address(factory),
            address(vaults),
            address(tokenUSDT),  // RIM accept asset
            address(core),
            address(oracle)
        );

        // ── 9. Register assets ──
        // ETH: 75% LTV, 5% liq penalty, mode 0
        manager.licensedAssetsRegister(
            address(tokenETH),
            7500, 500, 0, 7000, 1000, 0, 9500, 450, true
        );
        // USDT: 95% LTV, 3% liq penalty, mode 0 (same mode as ETH for cross-asset)
        manager.licensedAssetsRegister(
            address(tokenUSDT),
            9500, 300, 0, 7600, 1000, 0, 9700, 400, true
        );

        // ── 10. Get deposit/loan coin addresses ──
        address[2] memory pairETH  = manager.assetsDepositAndLendAddrs(address(tokenETH));
        depositCoinETH = pairETH[0];
        loanCoinETH    = pairETH[1];

        address[2] memory pairUSDT = manager.assetsDepositAndLendAddrs(address(tokenUSDT));
        depositCoinUSDT = pairUSDT[0];
        loanCoinUSDT    = pairUSDT[1];

        // ── 11. Whitelist this contract as interface ──
        manager.xInterfacesetting(address(this), true);

        // ── 12. Users approve interface ──
        vm.prank(alice);
        manager.setInterfaceApproval(true);
        vm.prank(bob);
        manager.setInterfaceApproval(true);
        vm.prank(liquidator);
        manager.setInterfaceApproval(true);

        // ── 13. Mint tokens ──
        tokenETH.mint(alice,      100 ether);
        tokenETH.mint(bob,        100 ether);
        tokenETH.mint(liquidator, 100 ether);

        tokenUSDT.mint(alice,      1_000_000e6);
        tokenUSDT.mint(bob,        1_000_000e6);
        tokenUSDT.mint(liquidator, 1_000_000e6);

        // ── 14. Approve manager ──
        vm.prank(alice);
        tokenETH.approve(address(manager), type(uint256).max);
        vm.prank(alice);
        tokenUSDT.approve(address(manager), type(uint256).max);

        vm.prank(bob);
        tokenETH.approve(address(manager), type(uint256).max);
        vm.prank(bob);
        tokenUSDT.approve(address(manager), type(uint256).max);

        vm.prank(liquidator);
        tokenETH.approve(address(manager), type(uint256).max);
        vm.prank(liquidator);
        tokenUSDT.approve(address(manager), type(uint256).max);
    }

    // =====================================================================
    //  1. ORACLE PRICE READS
    // =====================================================================

    function test_ETH_PriceIsReasonable() public {
        uint price = oracle.getPrice(address(tokenETH));
        // ETH should be between $100 and $100,000
        assertGt(price, 100 ether,    "ETH price too low");
        assertLt(price, 100_000 ether, "ETH price too high");
        emit log_named_uint("ETH price (18 dec USD)", price);
    }

    function test_USDT_PriceIsReasonable() public {
        uint price = oracle.getPrice(address(tokenUSDT));
        // USDT should be between $0.90 and $1.10
        assertGt(price, 0.90 ether, "USDT price too low");
        assertLt(price, 1.10 ether, "USDT price too high");
        emit log_named_uint("USDT price (18 dec USD)", price);
    }

    function test_USDC_PriceIsReasonable() public {
        // Read directly from oracle (not registered as asset, just testing feed)
        oracle.setTokenFeed(address(0xBEEF), FEED_USDC);
        uint price = oracle.getPrice(address(0xBEEF));
        assertGt(price, 0.90 ether, "USDC price too low");
        assertLt(price, 1.10 ether, "USDC price too high");
        emit log_named_uint("USDC price (18 dec USD)", price);
    }

    function test_WBTC_PriceIsReasonable() public {
        oracle.setTokenFeed(address(0xDEAD), FEED_WBTC);
        uint price = oracle.getPrice(address(0xDEAD));
        // BTC should be between $10,000 and $500,000
        assertGt(price, 10_000 ether,  "WBTC price too low");
        assertLt(price, 500_000 ether, "WBTC price too high");
        emit log_named_uint("WBTC price (18 dec USD)", price);
    }

    function test_UnmappedTokenReverts() public {
        vm.expectRevert("Zerrow Oracle: No feed for token");
        oracle.getPrice(address(0x9999));
    }

    // =====================================================================
    //  2. STALENESS CHECK
    // =====================================================================

    function test_StalePriceReverts() public {
        // Warp 8 hours into the future (past 7h maxStaleness)
        vm.warp(block.timestamp + 8 hours);
        vm.expectRevert("Zerrow Oracle: Stale price");
        oracle.getPrice(address(tokenETH));
    }

    function test_FreshPriceDoesNotRevert() public {
        // Warp 6 hours — still within 7h window
        vm.warp(block.timestamp + 6 hours);
        uint price = oracle.getPrice(address(tokenETH));
        assertGt(price, 0, "Price should be non-zero");
    }

    function test_IsFeedStaleHelper() public {
        assertFalse(oracle.isFeedStale(address(tokenETH)));
        vm.warp(block.timestamp + 8 hours);
        assertTrue(oracle.isFeedStale(address(tokenETH)));
    }

    // =====================================================================
    //  3. DEPOSIT + BORROW
    // =====================================================================

    function test_DepositAndBorrow() public {
        uint depositAmount = 10 ether; // 10 "ETH"

        // Alice deposits 10 ETH (alice calls directly, msg.sender == user bypasses interface check)
        vm.prank(alice);
        manager.assetsDeposit(address(tokenETH), depositAmount, alice);

        // Check deposit coin balance
        uint depositBal = iDepositOrLoanCoin(depositCoinETH).balanceOf(alice);
        assertEq(depositBal, depositAmount, "Deposit coin mismatch");

        // Health factor should be max (no loans)
        uint hf = manager.viewUsersHealthFactor(alice);
        assertEq(hf, 1000 ether, "HF should be max with no loans");

        // Now borrow USDT
        // ETH price ~$2200, deposit = 10 ETH = ~$22,000, LTV 75% = ~$16,500 borrowable
        // Borrow $1000 worth of USDT (well within limits)
        uint borrowAmount = 1000e6; // 1000 USDT (6 decimals)

        // First, seed the vault with USDT so there's something to borrow
        // Bob deposits USDT into the protocol
        vm.prank(bob);
        manager.assetsDeposit(address(tokenUSDT), 100_000e6, bob);

        // Alice borrows USDT
        vm.prank(alice);
        manager.lendAsset(address(tokenUSDT), borrowAmount, alice);

        // Check loan balance
        uint loanBal = iDepositOrLoanCoin(loanCoinUSDT).balanceOf(alice);
        assertGt(loanBal, 0, "Should have loan balance");

        // Health factor should be healthy but less than max
        hf = manager.viewUsersHealthFactor(alice);
        assertGt(hf, 1.2 ether, "HF should be above liquidation floor");
        assertLt(hf, 1000 ether, "HF should no longer be max");

        emit log_named_uint("Health factor after borrow", hf);
    }

    // =====================================================================
    //  4. REPAY LOAN
    // =====================================================================

    function test_RepayLoan() public {
        // Setup: deposit ETH, fund vault with USDT, borrow USDT
        _depositAndBorrow(alice, 10 ether, 1000e6);

        uint hfBefore = manager.viewUsersHealthFactor(alice);

        // Alice repays 500 USDT
        vm.prank(alice);
        manager.repayLoan(address(tokenUSDT), 500e6, alice);

        uint hfAfter = manager.viewUsersHealthFactor(alice);
        assertGt(hfAfter, hfBefore, "HF should improve after repay");

        emit log_named_uint("HF before repay", hfBefore);
        emit log_named_uint("HF after repay",  hfAfter);
    }

    function test_FullRepay() public {
        _depositAndBorrow(alice, 10 ether, 1000e6);

        // Get exact loan balance and repay it all
        uint loanBal = iDepositOrLoanCoin(loanCoinUSDT).balanceOf(alice);
        uint repayRaw = loanBal * (10**6) / 1 ether; // Convert 18-dec normalized to 6-dec raw
        if (repayRaw == 0) repayRaw = 1; // minimum

        // Give alice enough to repay (she got the borrowed USDT but needs exact amount)
        tokenUSDT.mint(alice, 10_000e6); // extra buffer

        vm.prank(alice);
        manager.repayLoan(address(tokenUSDT), repayRaw, alice);

        uint hf = manager.viewUsersHealthFactor(alice);
        assertEq(hf, 1000 ether, "HF should be max after full repay");
    }

    // =====================================================================
    //  5. WITHDRAW COLLATERAL
    // =====================================================================

    function test_WithdrawAfterRepay() public {
        // Deposit, borrow, repay, then withdraw
        _depositAndBorrow(alice, 10 ether, 1000e6);

        // Repay all
        uint loanBal = iDepositOrLoanCoin(loanCoinUSDT).balanceOf(alice);
        uint repayRaw = loanBal * (10**6) / 1 ether;
        tokenUSDT.mint(alice, 10_000e6);

        vm.prank(alice);
        manager.repayLoan(address(tokenUSDT), repayRaw, alice);

        // Withdraw 5 ETH
        uint balBefore = tokenETH.balanceOf(alice);
        vm.prank(alice);
        manager.withdrawDeposit(address(tokenETH), 5 ether, alice);
        uint balAfter = tokenETH.balanceOf(alice);

        assertEq(balAfter - balBefore, 5 ether, "Should receive 5 ETH back");
    }

    function test_WithdrawBlockedIfUndercollateralized() public {
        _depositAndBorrow(alice, 10 ether, 1000e6);

        // Try to withdraw too much ETH — should fail due to health factor
        vm.expectRevert(); // HF drops below floor
        vm.prank(alice);
        manager.withdrawDeposit(address(tokenETH), 9.9 ether, alice);
    }

    // =====================================================================
    //  6. LIQUIDATION
    // =====================================================================

    function test_Liquidation() public {
        // Alice deposits 10 ETH and borrows near the limit
        uint depositAmt = 10 ether;
        vm.prank(alice);
        manager.assetsDeposit(address(tokenETH), depositAmt, alice);

        // Seed USDT in vault (bob deposits)
        vm.prank(bob);
        manager.assetsDeposit(address(tokenUSDT), 500_000e6, bob);

        // Borrow close to limit
        // ETH ~$2200, 10 ETH = $22k, 75% LTV = $16.5k max
        // Borrow $10,000 USDT
        uint borrowAmt = 10_000e6;
        vm.prank(alice);
        manager.lendAsset(address(tokenUSDT), borrowAmt, alice);

        uint hf = manager.viewUsersHealthFactor(alice);
        emit log_named_uint("HF after heavy borrow", hf);

        // Lower ETH enough to make the position liquidatable, but not so far
        // underwater that every partial liquidation worsens the health factor.
        _mockFeedPrice(FEED_ETH, 1100e8); // ETH drops to $1100

        uint hfAfterCrash = manager.viewUsersHealthFactor(alice);
        emit log_named_uint("HF after ETH move to $1100", hfAfterCrash);
        assertLt(hfAfterCrash, 1 ether, "Should be liquidatable");

        // Liquidator repays USDT debt and receives underlying ETH collateral.
        uint liquidateAmt = 1_000e6; // repay 1,000 USDT of debt
        uint liquidatorEthBefore = tokenETH.balanceOf(liquidator);
        uint liquidatorDepositCoinBefore = iDepositOrLoanCoin(depositCoinETH).balanceOf(liquidator);
        uint aliceLoanBefore = iDepositOrLoanCoin(loanCoinUSDT).balanceOf(alice);
        uint seizedAmount;

        vm.prank(liquidator);
        seizedAmount = manager.tokenLiquidate(
            alice,
            address(tokenUSDT),  // debt token being repaid
            liquidateAmt,
            address(tokenETH)    // collateral token being seized
        );

        // Verify liquidator received underlying ETH rather than deposit-coin claims
        uint liqETHBal = tokenETH.balanceOf(liquidator);
        uint liqDepositBal = iDepositOrLoanCoin(depositCoinETH).balanceOf(liquidator);
        assertEq(liqETHBal - liquidatorEthBefore, seizedAmount, "Liquidator should have received underlying ETH");
        assertEq(liqDepositBal, liquidatorDepositCoinBefore, "Liquidator should not have received ETH deposit-coin claim");
        emit log_named_uint("Liquidator ETH balance increase", liqETHBal - liquidatorEthBefore);

        // Alice's debt and collateral should both have decreased
        uint aliceLoanAfter = iDepositOrLoanCoin(loanCoinUSDT).balanceOf(alice);
        uint aliceDepositAfter = iDepositOrLoanCoin(depositCoinETH).balanceOf(alice);
        assertLt(aliceLoanAfter, aliceLoanBefore, "Alice debt should decrease");
        assertLt(aliceDepositAfter, depositAmt, "Alice deposit should decrease");
        emit log_named_uint("Alice deposit after liquidation", aliceDepositAfter);
    }

    // =====================================================================
    //  7. MULTI-ASSET POSITIONS
    // =====================================================================

    function test_MultiAssetDeposit() public {
        // Alice deposits both ETH and USDT (both mode 0 now)
        vm.prank(alice);
        manager.assetsDeposit(address(tokenETH), 5 ether, alice);

        vm.prank(alice);
        manager.assetsDeposit(address(tokenUSDT), 10_000e6, alice);

        // Verify both deposit balances exist
        uint ethDeposit = iDepositOrLoanCoin(depositCoinETH).balanceOf(alice);
        uint usdtDeposit = iDepositOrLoanCoin(depositCoinUSDT).balanceOf(alice);
        assertEq(ethDeposit, 5 ether, "ETH deposit mismatch");
        assertEq(usdtDeposit, 10_000 ether, "USDT deposit mismatch (normalized to 18 dec)");

        // Verify oracle prices are independent and correct
        uint ethPrice = oracle.getPrice(address(tokenETH));
        uint usdtPrice = oracle.getPrice(address(tokenUSDT));

        emit log_named_uint("ETH price",  ethPrice);
        emit log_named_uint("USDT price", usdtPrice);

        // Verify ETH is significantly more expensive than USDT
        assertGt(ethPrice, usdtPrice * 100, "ETH should be >100x USDT price");

        // Health factor should reflect combined value
        uint hf = manager.viewUsersHealthFactor(alice);
        assertEq(hf, 1000 ether, "HF should be max with no loans");
    }

    // =====================================================================
    //  8. RAW PRICE DATA
    // =====================================================================

    function test_GetPriceRaw() public {
        (int256 answer, uint256 updatedAt, uint8 feedDecimals) = oracle.getPriceRaw(address(tokenETH));

        assertGt(answer, 0, "Raw answer should be positive");
        assertGt(updatedAt, 0, "UpdatedAt should be non-zero");
        assertEq(feedDecimals, 8, "Redstone feeds typically use 8 decimals");

        emit log_named_int("Raw ETH answer", answer);
        emit log_named_uint("Updated at", updatedAt);
        emit log_named_uint("Feed decimals", feedDecimals);
    }

    // =====================================================================
    //  HELPERS
    // =====================================================================

    /// @dev Deposits ETH for user, seeds USDT vault via bob, and borrows USDT for user
    function _depositAndBorrow(address user, uint ethAmount, uint usdtBorrowAmount) internal {
        // User deposits ETH
        vm.prank(user);
        manager.assetsDeposit(address(tokenETH), ethAmount, user);

        // Seed vault with USDT liquidity (bob deposits USDT)
        vm.prank(bob);
        manager.assetsDeposit(address(tokenUSDT), 100_000e6, bob);

        // User borrows USDT
        vm.prank(user);
        manager.lendAsset(address(tokenUSDT), usdtBorrowAmount, user);
    }

    /// @dev Mock a Redstone/Chainlink feed to return a specific price
    function _mockFeedPrice(address feed, int256 price) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(
                uint80(1),           // roundId
                price,               // answer
                block.timestamp,     // startedAt
                block.timestamp,     // updatedAt
                uint80(1)            // answeredInRound
            )
        );
        vm.mockCall(
            feed,
            abi.encodeWithSignature("decimals()"),
            abi.encode(uint8(8))
        );
    }
}
