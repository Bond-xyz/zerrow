# Zerrow Lending Protocol — Security Audit Report

**Date:** April 9, 2026
**Auditor:** Claude Code (Trail of Bits Skills Framework)
**Branch:** `feat/upgradeable-clean-redstone`
**Commit (pre-fix):** `251c20d`
**Commit (post-fix):** `5c28905`

---

## Scope

| Contract | Lines | Description |
|----------|-------|-------------|
| `lendingManager.sol` | ~650 | Core lending logic: deposit, withdraw, borrow, repay, liquidate, flash loan |
| `lendingVaults.sol` | ~120 | Token custody and approval gateway |
| `coinFactory.sol` | ~110 | Deposit/loan token deployer (BeaconProxy) |
| `zerrowOracleRedstone.sol` | ~110 | Redstone/Chainlink price feed oracle |
| `depositOrLoanCoin.sol` | ~200 | Interest-bearing position tokens (non-transferable) |
| `lendingCoreAlgorithm.sol` | ~80 | Interest rate model (3-tier curve) |
| `lendingInterface.sol` | ~900 | User-facing interface with native token wrapping |
| `lstInterface.sol` | ~800 | LST staking interface with leveraged looping |

**Total:** ~2,970 lines of Solidity across 8 contracts.

---

## Methodology

Four specialized audit agents were deployed in parallel, each following a distinct Trail of Bits audit framework:

| Agent | Framework | Focus |
|-------|-----------|-------|
| Agent 1 | Audit Context Building | Line-by-line analysis, invariant tracking, trust boundaries |
| Agent 2 | Entry Point Analyzer + Variant Analysis | Attack surface mapping, DeFi vulnerability pattern hunting |
| Agent 3 | Sharp Edges + Insecure Defaults | Configuration footguns, dangerous defaults, admin abuse |
| Agent 4 | Vulnerability Scanner | Code maturity scoring, systematic vulnerability detection |

---

## Code Maturity Assessment

**Overall Score: 15/36 (42%)**

| Category | Score (0-4) | Notes |
|----------|-------------|-------|
| Arithmetic | 2 | Solidity 0.8 overflow protection; precision loss in division patterns |
| Auditing/Events | 2 | Events exist but liquidation emitted wrong event types |
| Access Controls | 2 | Role separation exists; setter has unrestricted power |
| Complexity | 2 | lendingManager is a monolith; interface contracts heavily duplicated |
| Decentralization | 1 | Single setter controls everything; no timelock or governance |
| Documentation | 1 | Minimal NatSpec; no architecture documentation |
| MEV Risks | 1 | No slippage protection; no frontrun mitigation |
| Low-level Code | 3 | Minimal unsafe patterns; SafeERC20 used consistently |
| Testing | 1 | Limited test coverage pre-audit; no fuzz tests |

---

## Findings Summary

| Severity | Count | Fixed |
|----------|-------|-------|
| Critical | 3 | 3 |
| High | 9 | 7 |
| Medium | 15 | 2 |
| Low/Info | 8 | 1 |
| **Total** | **35** | **13** |

---

## Critical Findings

### C-1: Liquidation Function Has Swapped Deposit/Loan Indices

**Status: FIXED** | **Confirmed by: All 4 agents**
**Location:** `lendingManager.sol:610-620`

The `tokenLiquidate` function used array index `[0]` (deposit coin) where it should have used `[1]` (loan coin) and vice versa. This caused liquidation to burn collateral instead of reducing debt, and reduce debt on the wrong token.

```solidity
// BEFORE (broken):
uint amountLending = iDepositOrLoanCoin(assetsDepositAndLend[liquidateToken][0]).balanceOf(user);
uint amountDeposit = iDepositOrLoanCoin(assetsDepositAndLend[depositToken][1]).balanceOf(user);

// AFTER (fixed):
uint amountLending = iDepositOrLoanCoin(assetsDepositAndLend[liquidateToken][1]).balanceOf(user);
uint amountDeposit = iDepositOrLoanCoin(assetsDepositAndLend[depositToken][0]).balanceOf(user);
```

**Impact:** Liquidation was fundamentally broken. Would cause permanent bad debt accumulation or loss of user collateral without debt reduction.

**Test:** `test_LiquidationBurnsCorrectTokenTypes`

---

### C-2: Health Factor Floor Can Be Set to Zero

**Status: FIXED** | **Confirmed by: Agents 3, 4**
**Location:** `lendingManager.sol:209-212`

`setFloorOfHealthFactor` had no validation on either parameter. Setting both to 0 meant the health factor check `factor >= 0` always passed, allowing users to borrow the entire vault with dust collateral.

**Fix:** Added `require(normal >= 1 ether)` and `require(homogeneous >= 1 ether)`.

**Test:** `test_CannotSetHealthFactorFloorToZero`

---

### C-3: LTV Can Be Set to 9999 (99.99%)

**Status: FIXED** | **Confirmed by: Agent 3**
**Location:** `lendingManager.sol:225, 274`

`maximumLTV` could be set to 9999, meaning $100.01 collateral supports $100 in borrows. A 0.02% price drop makes the position instantly underwater. The liquidation penalty could also be set to 0, removing all incentive for liquidators.

**Fix:** Capped `_maxLTV` at 9500 (95%). Added minimum `_liqPenalty >= 100` (1%).

**Test:** `test_CannotSetLTVAbove9500`

---

## High Severity Findings

### H-1: Core Lending Functions Lack Reentrancy Protection

**Status: FIXED** | **Confirmed by: Agents 2, 4**
**Location:** `lendingManager.sol:449, 470, 499, 536`

`assetsDeposit`, `withdrawDeposit`, `lendAsset`, and `repayLoan` had no `nonReentrant` modifier. The flash loan callback could call these functions during execution to manipulate positions.

**Fix:** Added `nonReentrant` to all four functions.

**Test:** `test_CoreFunctionsHaveReentrancyGuard`

---

### H-2: Flash Loan Missing Vault Approval for Borrow Token

**Status: FIXED** | **Confirmed by: Agents 1, 2, 4**
**Location:** `lendingManager.sol:584`

`executeFlashLoan` attempted `safeTransferFrom(lendingVault, user, borrowAmount)` for `borrowTokenAddr` without calling `vaultsERC20Approve` first. Flash loans always reverted when `borrowTokenAddr != useTokenAddr`. Additionally, `borrowTokenAddr` was never validated as a licensed asset.

**Fix:** Added `vaultsERC20Approve` calls for both fee and borrow transfers. Added licensed asset validation for `borrowTokenAddr`.

---

### H-3: Liquidation Penalty Can Be Zero

**Status: FIXED (via C-3)** | **Confirmed by: Agent 3**
**Location:** `lendingManager.sol:225-226`

No minimum on `_liqPenalty`. At 0, liquidators have zero profit incentive, so liquidations never happen and bad debt accumulates.

**Fix:** `require(_liqPenalty >= 100)` (1% minimum).

---

### H-4: Oracle Feed Can Be Set to address(0)

**Status: FIXED** | **Confirmed by: Agent 3**
**Location:** `zerrowOracleRedstone.sol:59`

Setting a feed to `address(0)` caused `getPrice` to revert. Since health factor computation loops over ALL assets, one zeroed feed blocked ALL operations for ALL users.

**Fix:** `require(feed != address(0))` in `setTokenFeed` and `setTokenFeedBatch`.

**Test:** `test_CannotSetOracleFeedToZero`

---

### H-5: setup() and Setter Functions Accept Zero Addresses

**Status: FIXED** | **Confirmed by: Agents 3, 4**
**Location:** `lendingManager.sol:171-181`, `lendingVaults.sol:82-87`, `zerrowOracleRedstone.sol:78-80`

Critical contract addresses could be set to `address(0)` with no validation, causing silent failures or DoS.

**Fix:** Added zero-address checks to `setup()`, `setManager()`, `setRebalancer()`, `setSt0gAdr()`, and `transferSetter()`.

**Test:** `test_SetupRejectsZeroAddresses`, `test_TransferSetterRejectsZero`

---

### H-6: maxStaleness Has No Upper Bound

**Status: FIXED** | **Confirmed by: Agents 2, 3**
**Location:** `zerrowOracleRedstone.sol:73-76`

Could be set to `type(uint).max`, disabling staleness checks. Year-old prices would be accepted.

**Fix:** `require(_maxStaleness <= 86400)` (24 hour ceiling).

**Test:** `test_CannotSetMaxStalenessAbove24Hours`

---

### H-7: lstInterface Token Theft via Balance-Based Transfers

**Status: NOT YET FIXED** | **Confirmed by: Agent 4**
**Location:** `lstInterface.sol:712-734`

`lstStake` transfers the contract's entire gToken balance to `msg.sender`, including residual tokens from previous operations.

**Recommendation:** Track balance before/after staking and transfer only the delta.

---

### H-8: lendAsset2 Fails to Transfer Non-W0G Tokens

**Status: FIXED** | **Confirmed by: Agents 2, 4**
**Location:** `lendingInterface.sol:807-814`

`else if` logic meant that if the contract had any W0G dust, borrowed non-W0G tokens were permanently stuck.

**Fix:** Changed `else if` to separate `if` blocks.

---

### H-9: Setter Has God-Mode Power With No Timelock

**Status: NOT YET FIXED** | **Confirmed by: Agent 4**
**Location:** Multiple

The setter can instantly upgrade contracts, change oracle, set extreme parameters, and pause everything. No timelock or multi-sig requirement.

**Recommendation:** Implement timelock for critical parameter changes. Use multi-sig for setter.

---

## Medium Severity Findings

| ID | Finding | Location | Status |
|----|---------|----------|--------|
| M-1 | Flash loan fee in 18-dec space used for raw ERC20 transfer | `lendingManager.sol:580` | Open |
| M-2 | No partial liquidation limit (no close factor) | `lendingManager.sol:599-632` | Open |
| M-3 | No post-liquidation health factor check | `lendingManager.sol:599-632` | Open |
| M-4 | Self-liquidation not prevented | `lendingManager.sol:599` | Open |
| M-5 | Liquidation emits wrong events | `lendingManager.sol:630-631` | **Fixed** |
| M-6 | BadDebtDeduction event declared but never emitted | `lendingManager.sol:125` | Open |
| M-7 | OQC accounting drift from defensive underflow | `depositOrLoanCoin.sol:143-152` | Open |
| M-8 | VaultTokensAmount underflow blocks all operations | `lendingManager.sol:356` | Open |
| M-9 | bestDepositInterestRate allows 9999 (rate explosion) | `lendingManager.sol:225-232` | Open |
| M-10 | flashLoanFeesAddress defaults to address(0) | `lendingManager.sol:580` | **Fixed** |
| M-11 | Contract starts unpaused with zero-address deps | `lendingManager.sol:132-139` | Open |
| M-12 | No asset deregistration mechanism | `lendingManager.sol:233` | Open |
| M-13 | looperDeposit unbounded loop iterations | `lstInterface.sol:741` | Open |
| M-14 | userModeSetting accepts arbitrary mode numbers | `lendingManager.sol:303-313` | Open |
| M-15 | Tokens sent to interface contracts stolen by next caller | `lendingInterface.sol:662-666` | Open |

---

## Low / Informational Findings

| ID | Finding | Location |
|----|---------|----------|
| L-1 | viewUsersHealthFactor has unreachable dead code | `lendingManager.sol:398` |
| L-2 | feedDecimals > 18 causes permanent revert | `zerrowOracleRedstone.sol:104` |
| L-3 | lendingCoreAlgorithm is not upgradeable | `lendingCoreAlgorithm.sol` |
| L-4 | approve() used instead of safeIncreaseAllowance | Multiple interface files |
| L-5 | lendingManager.transferSetter zero-address check missing | `lendingManager.sol:160` |
| L-6 | Interface admin role cannot be transferred | `lendingInterface.sol:47` |
| L-7 | setInterfaceApproval is all-or-nothing | `lendingManager.sol:201` |
| L-8 | No roundId validation in oracle | `zerrowOracleRedstone.sol:88` |

Note: L-5 was fixed as part of this audit.

---

## Test Coverage Added

10 new audit fix verification tests in `test/AuditFixVerification.t.sol`:

| Test | Validates |
|------|-----------|
| `test_LiquidationBurnsCorrectTokenTypes` | C-1: Correct deposit/loan indices in liquidation |
| `test_CannotSetHealthFactorFloorToZero` | C-2: Health factor floor >= 1 ether |
| `test_CannotSetLTVAbove9500` | C-3: LTV cap + min liquidation penalty |
| `test_CoreFunctionsHaveReentrancyGuard` | H-1: nonReentrant on core functions |
| `test_CannotSetOracleFeedToZero` | H-4: Oracle feed != address(0) |
| `test_CannotSetMaxStalenessAbove24Hours` | H-6: maxStaleness <= 86400 |
| `test_SetupRejectsZeroAddresses` | H-5: Zero-address validation in setup() |
| `test_StalePriceReverts` | Oracle staleness enforcement |
| `test_TransferSetterRejectsZero` | L-5: transferSetter != address(0) |
| `test_FlashLoanRequiresFeesAddress` | M-10: flashLoanFeesAddress required |

16 additional fork tests in `test/RedstoneOracleForkTest.t.sol` verify the Redstone oracle integration against live 0G Galileo testnet feeds (ETH, USDT, USDC, WBTC).

**Total test results:** 58/58 non-fork tests pass. 16/16 fork tests pass (with `--fork-url`).

---

## Recommendations

1. **Implement a timelock** for all setter operations that change critical protocol parameters (oracle address, LTV, health factor floors, contract upgrades).

2. **Use a multi-sig wallet** for the setter role across all contracts.

3. **Add a close factor** to liquidations (e.g., max 50% of position per tx) to prevent full-position liquidation in one transaction.

4. **Implement bad debt socialization** — the `BadDebtDeduction` event is declared but never used. Consider a reserve fund or insurance mechanism.

5. **Add asset deregistration** — currently there is no way to remove a compromised asset, and one broken oracle feed blocks all users.

6. **Fix lstInterface balance-based transfers** (H-7) — use before/after delta pattern to prevent token theft.

7. **Add bounds to bestDepositInterestRate** (M-9) — the code comments suggest max 1000 (10%) but allows up to 9999.

8. **Start contracts in paused state** (M-11) — initialize with `_pause()` and require explicit unpause after full configuration.

---

## Files Modified in This Audit

| File | Changes |
|------|---------|
| `contracts/lendingManager.sol` | C-1, C-2, C-3, H-1, H-2, H-5, M-5, M-10, L-5 |
| `contracts/zerrowOracleRedstone.sol` | H-4, H-5, H-6 |
| `contracts/lendingVaults.sol` | H-5 |
| `contracts/lendingInterface.sol` | H-8 |
| `test/AuditFixVerification.t.sol` | New (10 tests) |
| `test/RedstoneOracleForkTest.t.sol` | New (16 fork tests) |
