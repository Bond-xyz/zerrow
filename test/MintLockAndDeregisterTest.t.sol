// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "./utils/TestBase.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../contracts/lendingManager.sol";
import "../contracts/lendingVaults.sol";
import "../contracts/coinFactory.sol";
import "../contracts/template/depositOrLoanCoin.sol";
import "../contracts/test/MockERC20.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockOracleML {
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

contract MockRewardML {
    function factoryUsedRegister(address, uint256) external returns (bool) {
        return true;
    }
    function recordUpdate(address, uint256) external returns (bool) {
        return true;
    }
}

contract MockCoreAlgorithmML {
    function assetsValueUpdate(address) external pure returns (uint256[2] memory result) {
        result[0] = 100;
        result[1] = 200;
    }

    function depositInterestRate(address, uint256) external pure returns (uint256) {
        return 100;
    }

    function lendingInterestRate(address, uint256, uint256) external pure returns (uint256) {
        return 200;
    }
}

// ===========================================================================
//  Full integration test harness — deploys the entire lending stack
// ===========================================================================

contract MintLockAndDeregisterTestBase is TestBase {
    // ── Actors ───────────────────────────────────────────────
    address public setter   = address(0xA1);
    address public nonSetter = address(0xB1);
    address public user1    = address(0xC1);

    // ── Core contracts (behind proxies) ─────────────────────
    lendingManager public manager;
    lendingVaults  public vaults;
    coinFactory    public factory;

    // ── Supporting contracts ────────────────────────────────
    MockOracleML        public oracle;
    MockRewardML        public reward;
    MockCoreAlgorithmML public coreAlgo;
    UpgradeableBeacon   public beacon;

    // ── Tokens ─────────────────────────────────────────────
    MockERC20 public tokenA;  // e.g. W0G (the one we want to restrict)
    MockERC20 public tokenB;  // e.g. USDC.e (normal market)

    // ── Coin addresses (filled after registration) ──────────
    address public tokenA_depositCoin;
    address public tokenA_loanCoin;
    address public tokenB_depositCoin;
    address public tokenB_loanCoin;

    function setUp() public virtual {
        // Deploy mock infrastructure
        oracle   = new MockOracleML();
        reward   = new MockRewardML();
        coreAlgo = new MockCoreAlgorithmML();

        // Deploy tokens
        tokenA = new MockERC20("Wrapped 0G", "W0G", 18);
        tokenB = new MockERC20("USD Coin",   "USDC.e", 6);

        // ── Deploy lendingManager proxy ─────────────────────
        {
            lendingManager impl = new lendingManager();
            bytes memory initData = abi.encodeWithSelector(
                lendingManager.initialize.selector, setter
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            manager = lendingManager(address(proxy));
        }

        // ── Deploy lendingVaults proxy ──────────────────────
        {
            lendingVaults impl = new lendingVaults();
            bytes memory initData = abi.encodeWithSelector(
                lendingVaults.initialize.selector, setter
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            vaults = lendingVaults(payable(address(proxy)));
        }

        // ── Deploy coinFactory proxy ────────────────────────
        {
            coinFactory impl = new coinFactory();
            bytes memory initData = abi.encodeWithSelector(
                coinFactory.initialize.selector, setter
            );
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
            factory = coinFactory(address(proxy));
        }

        // ── Deploy beacon for depositOrLoanCoin ─────────────
        {
            depositOrLoanCoin coinImpl = new depositOrLoanCoin();
            beacon = new UpgradeableBeacon(address(coinImpl));
        }

        // ── Wire everything together ────────────────────────
        vm.startPrank(setter);

        // lendingManager.setup
        manager.setup(
            address(factory),
            address(vaults),
            address(0),          // riskIsolationModeAcceptAssets (unused here)
            address(coreAlgo),
            address(oracle)
        );

        // lendingVaults — set manager
        vaults.setManager(address(manager));

        // coinFactory — set lendingManager, reward, beacon, types
        factory.settings(address(manager), address(reward));
        factory.rewardTypeSetup(1, 2);
        factory.setBeacon(address(beacon));

        // Oracle prices (18-decimal USD prices)
        oracle.setPrice(address(tokenA), 0.05 ether);  // W0G = $0.05
        oracle.setPrice(address(tokenB), 1 ether);      // USDC = $1.00

        // Whitelist the test contract as an interface so it can call
        // assetsDeposit / lendAsset / repayLoan on behalf of users.
        manager.xInterfacesetting(address(this), true);

        // ── Register token A (W0G) ──────────────────────────
        manager.licensedAssetsRegister(
            address(tokenA),
            6000,  // maxLTV 60%
            1200,  // liqPenalty 12%
            0,     // maxLendingAmountInRIM
            6000,  // bestLendingRatio
            1200,  // reserveFactor
            3,     // lendingModeNum
            8000,  // homogeneousModeLTV
            500,   // bestDepositInterestRate
            true   // isNew — creates coins
        );

        // ── Register token B (USDC.e) ───────────────────────
        manager.licensedAssetsRegister(
            address(tokenB),
            9000,  // maxLTV 90%
            1000,  // liqPenalty 10%
            0,     // maxLendingAmountInRIM
            8500,  // bestLendingRatio
            1000,  // reserveFactor
            2,     // lendingModeNum
            9500,  // homogeneousModeLTV
            400,   // bestDepositInterestRate
            true   // isNew
        );

        vm.stopPrank();

        // Capture coin addresses
        address[2] memory coinsA = manager.assetsDepositAndLendAddrs(address(tokenA));
        tokenA_depositCoin = coinsA[0];
        tokenA_loanCoin    = coinsA[1];

        address[2] memory coinsB = manager.assetsDepositAndLendAddrs(address(tokenB));
        tokenB_depositCoin = coinsB[0];
        tokenB_loanCoin    = coinsB[1];
    }
}

// ===========================================================================
//  1.  coinMintLockerSetup — Access Control
// ===========================================================================

contract CoinMintLockerAccessControlTest is MintLockAndDeregisterTestBase {

    function test_setter_can_lock_loan_coin() public {
        // Pre-condition: mint lock is off
        assertFalse(depositOrLoanCoin(tokenA_loanCoin).mintlock());

        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        assertTrue(depositOrLoanCoin(tokenA_loanCoin).mintlock());
    }

    function test_setter_can_unlock_loan_coin() public {
        // Lock first
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);
        assertTrue(depositOrLoanCoin(tokenA_loanCoin).mintlock());

        // Unlock
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, false);
        assertFalse(depositOrLoanCoin(tokenA_loanCoin).mintlock());
    }

    function test_setter_can_lock_deposit_coin() public {
        // Should also work on deposit coins (e.g. emergency freeze deposits)
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_depositCoin, true);

        assertTrue(depositOrLoanCoin(tokenA_depositCoin).mintlock());
    }

    function test_nonSetter_cannot_call_coinMintLockerSetup() public {
        vm.prank(nonSetter);
        vm.expectRevert("Lending Manager: Only Setter Use");
        manager.coinMintLockerSetup(tokenA_loanCoin, true);
    }

    function test_random_user_cannot_call_coinMintLockerSetup() public {
        vm.prank(user1);
        vm.expectRevert("Lending Manager: Only Setter Use");
        manager.coinMintLockerSetup(tokenA_loanCoin, true);
    }

    function test_lock_one_asset_does_not_affect_another() public {
        // Lock token A loan coin
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Token B loan coin should still be unlocked
        assertTrue(depositOrLoanCoin(tokenA_loanCoin).mintlock());
        assertFalse(depositOrLoanCoin(tokenB_loanCoin).mintlock());
    }

    function test_lock_loan_does_not_affect_deposit() public {
        // Lock token A loan coin
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Token A deposit coin should still be unlocked
        assertTrue(depositOrLoanCoin(tokenA_loanCoin).mintlock());
        assertFalse(depositOrLoanCoin(tokenA_depositCoin).mintlock());
    }

    function test_idempotent_lock() public {
        // Locking twice should not revert
        vm.startPrank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);
        vm.stopPrank();

        assertTrue(depositOrLoanCoin(tokenA_loanCoin).mintlock());
    }

    function test_idempotent_unlock() public {
        // Unlocking when already unlocked should not revert
        vm.startPrank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, false);
        vm.stopPrank();

        assertFalse(depositOrLoanCoin(tokenA_loanCoin).mintlock());
    }
}

// ===========================================================================
//  2.  coinMintLockerSetup — Borrow Blocking Behavior
// ===========================================================================

contract CoinMintLockerBorrowBlockingTest is MintLockAndDeregisterTestBase {

    /// @dev Helper: deposit collateral (tokenB) for user via the test contract
    ///      acting as the whitelisted interface.
    function _depositCollateral(address borrower, uint256 collateralAmt) internal {
        // User approves the test contract as their interface
        vm.prank(borrower);
        manager.setInterfaceApproval(true);

        // Mint collateral to the test contract (it's the interface / msg.sender)
        tokenB.mint(address(this), collateralAmt);
        tokenB.approve(address(manager), collateralAmt);

        // Interface deposits on behalf of user
        manager.assetsDeposit(address(tokenB), collateralAmt, borrower);
    }

    function test_locked_loan_coin_blocks_borrow() public {
        // Lock W0G borrowing
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Fund vault with tokenA for borrow liquidity
        tokenA.mint(address(vaults), 1000 ether);

        // Deposit collateral for user1
        _depositCollateral(user1, 10000 * 1e6);

        // Attempt to borrow tokenA — should revert with mint lock message
        vm.expectRevert("Deposit Or Loan Coin: Mint function locked");
        manager.lendAsset(address(tokenA), 100 ether, user1);
    }

    function test_unlocked_loan_coin_allows_borrow_then_lock_blocks() public {
        // Supply tokenA as deposits first (to satisfy 99% utilization cap)
        address supplier = address(0xD1);
        vm.prank(supplier);
        manager.setInterfaceApproval(true);
        tokenA.mint(address(this), 10000 ether);
        tokenA.approve(address(manager), 10000 ether);
        manager.assetsDeposit(address(tokenA), 10000 ether, supplier);

        // Deposit collateral (tokenB) for borrower
        _depositCollateral(user1, 100000 * 1e6);

        // Borrow should succeed when unlocked
        manager.lendAsset(address(tokenA), 10 ether, user1);

        // Verify loan coin was minted
        assertTrue(depositOrLoanCoin(tokenA_loanCoin).balanceOf(user1) > 0);

        // Now lock it
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Second borrow attempt should fail
        vm.expectRevert("Deposit Or Loan Coin: Mint function locked");
        manager.lendAsset(address(tokenA), 10 ether, user1);
    }

    function test_lock_loan_does_not_block_deposits() public {
        // Lock W0G loan coin (borrowing)
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Deposit tokenA (supply) should still work
        uint256 depositAmount = 100 ether;
        tokenA.mint(address(this), depositAmount);
        tokenA.approve(address(manager), depositAmount);

        vm.prank(user1);
        manager.setInterfaceApproval(true);

        // This should succeed — deposit coin is NOT locked
        manager.assetsDeposit(address(tokenA), depositAmount, user1);

        assertTrue(depositOrLoanCoin(tokenA_depositCoin).balanceOf(user1) > 0);
    }

    function test_lock_does_not_block_repayment() public {
        // Supply tokenA as deposits first (to satisfy 99% utilization cap)
        address supplier = address(0xD1);
        vm.prank(supplier);
        manager.setInterfaceApproval(true);
        tokenA.mint(address(this), 10000 ether);
        tokenA.approve(address(manager), 10000 ether);
        manager.assetsDeposit(address(tokenA), 10000 ether, supplier);

        // Deposit collateral (tokenB) for borrower
        _depositCollateral(user1, 100000 * 1e6);

        // Borrow some tokenA
        uint256 borrowAmount = 10 ether;
        manager.lendAsset(address(tokenA), borrowAmount, user1);

        // Now lock the loan coin
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Repayment should still work (burnCoin does NOT check mintLocker).
        // The interface (this contract) needs the tokens to repay.
        tokenA.mint(address(this), borrowAmount);
        tokenA.approve(address(manager), borrowAmount);

        manager.repayLoan(address(tokenA), borrowAmount, user1);
    }
}

// ===========================================================================
//  3.  licensedAssetsDeregister — Access Control
// ===========================================================================

contract DeregisterAccessControlTest is MintLockAndDeregisterTestBase {

    function test_nonSetter_cannot_deregister() public {
        vm.prank(nonSetter);
        vm.expectRevert("Lending Manager: Only Setter Use");
        manager.licensedAssetsDeregister(address(tokenA));
    }

    function test_cannot_deregister_unregistered_asset() public {
        address fakeToken = address(0xDEAD);

        vm.prank(setter);
        vm.expectRevert("Lending Manager: asset is Not registered!");
        manager.licensedAssetsDeregister(fakeToken);
    }
}

// ===========================================================================
//  4.  licensedAssetsDeregister — Functional Behavior
// ===========================================================================

contract DeregisterFunctionalTest is MintLockAndDeregisterTestBase {

    function test_deregister_clears_licensedAssets() public {
        // Pre-condition: tokenA is registered
        (address assetAddr,,,,,,,,) = manager.licensedAssets(address(tokenA));
        assertEq(assetAddr, address(tokenA));

        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        // Post-condition: licensedAssets mapping cleared
        (assetAddr,,,,,,,,) = manager.licensedAssets(address(tokenA));
        assertEq(assetAddr, address(0));
    }

    function test_deregister_clears_assetsDepositAndLend() public {
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        address[2] memory coins = manager.assetsDepositAndLendAddrs(address(tokenA));
        assertEq(coins[0], address(0));
        assertEq(coins[1], address(0));
    }

    function test_deregister_removes_from_assetsSerialNumber() public {
        // Before: 2 assets registered
        assertEq(manager.licensedAssetAmount(), 2);

        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        // After: 1 asset
        assertEq(manager.licensedAssetAmount(), 1);

        // Remaining asset should be tokenB
        assertEq(manager.assetsSerialNumber(0), address(tokenB));
    }

    function test_deregister_last_asset() public {
        // Deregister both assets
        vm.startPrank(setter);
        manager.licensedAssetsDeregister(address(tokenA));
        manager.licensedAssetsDeregister(address(tokenB));
        vm.stopPrank();

        assertEq(manager.licensedAssetAmount(), 0);
    }

    function test_deregister_first_asset_preserves_second() public {
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        // tokenB should still be fully functional
        (address assetAddr,,,,,,,,) = manager.licensedAssets(address(tokenB));
        assertEq(assetAddr, address(tokenB));
        assertEq(manager.licensedAssetAmount(), 1);
    }

    function test_cannot_deregister_with_outstanding_deposits() public {
        // Deposit tokenA via the test contract (whitelisted interface)
        uint256 depositAmount = 100 ether;
        tokenA.mint(address(this), depositAmount);
        tokenA.approve(address(manager), depositAmount);

        vm.prank(user1);
        manager.setInterfaceApproval(true);

        manager.assetsDeposit(address(tokenA), depositAmount, user1);

        // Deposit coin has non-zero totalSupply now
        assertTrue(depositOrLoanCoin(tokenA_depositCoin).totalSupply() > 0);

        // Attempt to deregister — should fail
        vm.prank(setter);
        vm.expectRevert("Lending Manager: Outstanding positions exist");
        manager.licensedAssetsDeregister(address(tokenA));
    }

    function test_cannot_deregister_with_outstanding_borrows() public {
        // Supply tokenA as deposits first (to satisfy 99% utilization cap)
        address supplier = address(0xD1);
        vm.prank(supplier);
        manager.setInterfaceApproval(true);
        tokenA.mint(address(this), 10000 ether);
        tokenA.approve(address(manager), 10000 ether);
        manager.assetsDeposit(address(tokenA), 10000 ether, supplier);

        // Deposit collateral (tokenB) and borrow tokenA
        uint256 collateralAmount = 100000 * 1e6;
        tokenB.mint(address(this), collateralAmount);
        tokenB.approve(address(manager), collateralAmount);

        vm.prank(user1);
        manager.setInterfaceApproval(true);

        manager.assetsDeposit(address(tokenB), collateralAmount, user1);
        manager.lendAsset(address(tokenA), 10 ether, user1);

        // Loan coin has non-zero totalSupply now
        assertTrue(depositOrLoanCoin(tokenA_loanCoin).totalSupply() > 0);

        // Attempt to deregister — should fail
        vm.prank(setter);
        vm.expectRevert("Lending Manager: Outstanding positions exist");
        manager.licensedAssetsDeregister(address(tokenA));
    }

    function test_deregister_blocks_new_deposits() public {
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        // Attempting to deposit tokenA should fail
        tokenA.mint(address(this), 100 ether);
        tokenA.approve(address(manager), 100 ether);

        vm.prank(user1);
        manager.setInterfaceApproval(true);

        vm.expectRevert("Lending Manager: Token not licensed");
        manager.assetsDeposit(address(tokenA), 100 ether, user1);
    }

    function test_deregister_blocks_new_borrows() public {
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        // Need user to have approved interface first
        vm.prank(user1);
        manager.setInterfaceApproval(true);

        // Attempting to borrow tokenA should fail
        vm.expectRevert("Lending Manager: Token not licensed");
        manager.lendAsset(address(tokenA), 10 ether, user1);
    }

    function test_cannot_double_deregister() public {
        vm.startPrank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        vm.expectRevert("Lending Manager: asset is Not registered!");
        manager.licensedAssetsDeregister(address(tokenA));
        vm.stopPrank();
    }

    function test_can_reregister_after_deregister() public {
        // Deregister
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        assertEq(manager.licensedAssetAmount(), 1);

        // Re-register with isNew=false (coins already exist in coinFactory)
        vm.prank(setter);
        manager.licensedAssetsRegister(
            address(tokenA),
            6000, 1200, 0, 6000, 1200, 3, 8000, 500,
            false  // isNew=false — reuse existing coins
        );

        assertEq(manager.licensedAssetAmount(), 2);

        // Verify asset is functional again
        (address assetAddr,,,,,,,,) = manager.licensedAssets(address(tokenA));
        assertEq(assetAddr, address(tokenA));
    }
}

// ===========================================================================
//  5.  Vulnerability / Edge Case Tests
// ===========================================================================

contract VulnerabilityTests is MintLockAndDeregisterTestBase {

    /// @notice Verify that coinMintLockerSetup reverts if called with an
    ///         address where the lendingManager is NOT the setter
    ///         (i.e. cannot lock arbitrary external contracts).
    function test_cannot_lock_unrelated_coin() public {
        // Deploy an independent depositOrLoanCoin with a different setter
        depositOrLoanCoin coinImpl = new depositOrLoanCoin();
        UpgradeableBeacon localBeacon = new UpgradeableBeacon(address(coinImpl));

        MockERC20 dummyToken = new MockERC20("Dummy", "DUM", 18);
        // Use a mock manager for getCoinValues
        MockLMForCoin mockLM = new MockLMForCoin();

        bytes memory initData = abi.encodeWithSelector(
            depositOrLoanCoin.initialize.selector,
            "Rogue Coin", "ROGUE",
            address(0xBEEF),     // setter = some other address, NOT the lendingManager
            address(dummyToken),
            address(mockLM),
            1,
            address(reward)
        );
        BeaconProxy bp = new BeaconProxy(address(localBeacon), initData);

        // Attempt to lock this external coin via the lendingManager
        vm.prank(setter);
        vm.expectRevert("Deposit Or Loan Coin: Only setter Use");
        manager.coinMintLockerSetup(address(bp), true);
    }

    /// @notice Verify swap-and-pop ordering after deregistering the first asset.
    ///         The last element moves into the removed slot.
    function test_deregister_swap_and_pop_ordering() public {
        // Register a third token
        MockERC20 tokenC = new MockERC20("Token C", "TC", 18);
        oracle.setPrice(address(tokenC), 0.1 ether);

        vm.prank(setter);
        manager.licensedAssetsRegister(
            address(tokenC),
            5000, 1000, 0, 5000, 1000, 5, 7000, 300, true
        );

        // State: [tokenA, tokenB, tokenC]
        assertEq(manager.licensedAssetAmount(), 3);
        assertEq(manager.assetsSerialNumber(0), address(tokenA));
        assertEq(manager.assetsSerialNumber(1), address(tokenB));
        assertEq(manager.assetsSerialNumber(2), address(tokenC));

        // Remove tokenA (index 0) — tokenC should move to index 0
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenA));

        assertEq(manager.licensedAssetAmount(), 2);
        assertEq(manager.assetsSerialNumber(0), address(tokenC));  // swapped in
        assertEq(manager.assetsSerialNumber(1), address(tokenB));  // unchanged
    }

    /// @notice Verify deregister removes the middle element correctly.
    function test_deregister_middle_element() public {
        MockERC20 tokenC = new MockERC20("Token C", "TC", 18);
        oracle.setPrice(address(tokenC), 0.1 ether);

        vm.prank(setter);
        manager.licensedAssetsRegister(
            address(tokenC),
            5000, 1000, 0, 5000, 1000, 5, 7000, 300, true
        );

        // State: [tokenA, tokenB, tokenC]
        // Remove tokenB (index 1) — tokenC should move to index 1
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenB));

        assertEq(manager.licensedAssetAmount(), 2);
        assertEq(manager.assetsSerialNumber(0), address(tokenA));
        assertEq(manager.assetsSerialNumber(1), address(tokenC));  // swapped in
    }

    /// @notice Verify deregister of the last element (no swap needed, just pop).
    function test_deregister_last_element() public {
        // State: [tokenA, tokenB]
        // Remove tokenB (last element) — just pops, no swap
        vm.prank(setter);
        manager.licensedAssetsDeregister(address(tokenB));

        assertEq(manager.licensedAssetAmount(), 1);
        assertEq(manager.assetsSerialNumber(0), address(tokenA));
    }

    /// @notice Verify that locking the loan coin + deregistering cannot be
    ///         combined to trap user funds.  If loan coin is locked and has
    ///         outstanding supply, deregister should still be blocked.
    function test_lock_and_deregister_cannot_trap_funds() public {
        // Setup: deposit tokenA via the test contract (interface)
        uint256 depositAmount = 100 ether;
        tokenA.mint(address(this), depositAmount);
        tokenA.approve(address(manager), depositAmount);

        vm.prank(user1);
        manager.setInterfaceApproval(true);

        manager.assetsDeposit(address(tokenA), depositAmount, user1);

        // Lock the loan coin
        vm.prank(setter);
        manager.coinMintLockerSetup(tokenA_loanCoin, true);

        // Attempt deregister — should fail because deposit coin has supply
        vm.prank(setter);
        vm.expectRevert("Lending Manager: Outstanding positions exist");
        manager.licensedAssetsDeregister(address(tokenA));
    }
}

/// @dev Helper mock for standalone coin tests
contract MockLMForCoin {
    function getCoinValues(address) external pure returns (uint256[2] memory values) {
        values[0] = 1 ether;
        values[1] = 1 ether;
    }
}
