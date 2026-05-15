# Zerrow

## What is Zerrow?

Zerrow is the **on-chain lending protocol** powering Bond's `/lend` module. Pool-based supply/borrow system (Aave/Compound-style) deployed on the 0G chain. Users deposit assets to earn interest, borrow against collateral, and face liquidation if health factor drops below threshold. Supports LST operations and flash loans.

**License**: BSL 1.1 (contracts) / MIT (scripts, tests)
**Solidity**: 0.8.6
**Framework**: Foundry + Hardhat (JS tests only)

---

## Architecture

### Core Contracts

| Contract | Pattern | Purpose |
|----------|---------|---------|
| `lendingManager` | UUPS proxy | Core monolith: asset registration, deposit/withdraw/borrow/repay/liquidation, flash loans, interest accrual, health factor |
| `lendingInterface` | UUPS proxy | User-facing entrypoint: wraps native 0G via W0G, delegates to lendingManager |
| `lstInterface` | UUPS proxy | LST staking entrypoint: deposit/borrow with st0G, leveraged looping |
| `lendingVaults` | UUPS proxy | Token custody: holds all deposited tokens, manages allowances. Pausable. |
| `coinFactory` | UUPS proxy | Factory: deploys deposit/loan position tokens as BeaconProxy instances |
| `depositOrLoanCoin` | BeaconProxy | Interest-bearing position token (non-transferable ERC20). Upgradeable via shared UpgradeableBeacon. |
| `lendingCoreAlgorithm` | Plain | Pure interest rate math: 3-tier utilization curve. Redeployed + re-pointed (no proxy). |
| `zerrowOracleRedstone` | UUPS proxy | Price oracle: maps tokens to Redstone/Chainlink feeds, enforces staleness (default 7h). |
| `w0G` | Plain | WETH-style wrapper for native 0G token |

### Upgrade Pattern

All core contracts use **UUPS (ERC1967)** proxies. `depositOrLoanCoin` uses **Beacon** pattern (one UpgradeableBeacon upgrades all instances). `lendingCoreAlgorithm` is non-proxy.

### Role System

- **setter**: Primary admin on lendingManager, lendingVaults, oracle. Configures assets, pauses, sets parameters.
- **admin**: Upgrade authority on lendingInterface, lstInterface. Two-step transfer.
- **setPermissionAddress**: Admin on coinFactory.
- **guardian**: Can pause lendingVaults (not unpause).
- **rebalancer**: Can rebalance vaults.

---

## Directory Structure

```
zerrow/
├── contracts/           # All Solidity source
│   ├── interfaces/      # 13 interface contracts (prefixed with lowercase i)
│   ├── mocks/           # Test tokens
│   ├── template/        # BeaconProxy base (depositOrLoanCoin)
│   ├── test/            # V2 upgrade test contracts
│   └── w0G/             # Wrapped 0G
├── script/              # Forge deployment scripts (Solidity)
│   ├── DeployProtocol.s.sol
│   ├── ConfigureMarkets.s.sol
│   ├── UpgradeContract.s.sol
│   └── DeployTimelock.s.sol
├── scripts/             # Shell wrappers
├── test/                # Foundry + Hardhat tests
├── config/              # Oracle feed map examples
├── deployments/         # Deployment manifest docs (no committed addresses in public repo)
└── foundry.toml
```

---

## Build / Test / Deploy

```bash
forge build

# Tests (3 suites)
npm test                       # All: protocol + upgrade + ops
npm run test:protocol          # AuditFixVerification
npm run test:upgrade           # Upgradeability
npm run test:ops               # OpsAndDeploymentParity
npm run test:fork              # Fork tests (needs ZERO_G_RPC_URL)

# Deploy (3-step operator flow)
make deploy                    # Deploy all protocol contracts
make configure-markets         # Register assets + set oracle feeds
make handoff-admin             # Transfer admin roles

# Upgrade single contract
make upgrade TARGET=lendingManager
```

---

## Environment Variables

**Deployment**: `PRIVATE_KEY`, `RPC_URL`, `W0G_ADDRESS`, `REWARD_CONTRACT_ADDRESS`, `BOND_ENV`
**Market config**: `ASSETS_REGISTRY_PATH` (shared asset registry JSON), `ORACLE_FEED_MAP_PATH`, `LENDING_MANAGER_ADDRESS`, `ORACLE_ADDRESS`
**Upgrade**: `UPGRADE_TARGET`, `DEPLOYMENT_FILE`, `DRY_RUN`

---

## Coding Conventions

- Contract names: **camelCase** (`lendingManager`, `coinFactory`)
- Interface names: lowercase `i` prefix (`iLendingManager`, `iDecimals`)
- Upgradeable contracts include: `constructor() initializer {}`, `__gap` storage slots, explicit `_authorizeUpgrade`
- Two-step admin transfer (transfer + accept)
- BPS-based math: 10000 = 100%
- Constants: `UPPER_CASE`

---

## Cross-Repo Connections

- **Downstream**: `bond-lending-contracts` (private) mirrors this code + adds committed ABIs and deployment addresses
- **Consumed by**: `bond-super-app` via `@bond/lending-contracts` package
- **Config source**: `ASSETS_REGISTRY_PATH` points to `bond-environments` asset registry
- **Indexed by**: `bond-lending` (Rust backend) scans chain for contract events
