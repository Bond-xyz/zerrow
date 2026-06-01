# Deployments

This directory stores generated deployment manifests for Zerrow environments.

The intended operator flow for Bond-style environments is:

1. `make deploy`
2. `make configure-markets`
3. `make handoff-admin`

## Required Environment

Core deployment:

- `PRIVATE_KEY`
- `RPC_URL`
- `W0G_ADDRESS`
- `REWARD_CONTRACT_ADDRESS` legacy `iRewardMini` compatibility hook address

Optional deployment overrides:

- `BOND_ENV` (`staging` by default)
- `DEPLOYMENT_FILE`
- `DEPLOY_MOCK_REWARD=1` deploys a compatibility mock hook
- `RISK_ISOLATION_MODE_ACCEPT_ASSET`
- `NORMAL_HEALTH_FACTOR_BPS`
- `HOMOGENEOUS_HEALTH_FACTOR_BPS`
- `REWARD_DEPOSIT_TYPE`
- `REWARD_LOAN_TYPE`
- `ORACLE_MAX_STALENESS`
- `ST0G_ADDRESS`

Market configuration:

- `ASSETS_REGISTRY_PATH` (required, no repo-specific default)
- `ORACLE_FEED_MAP_PATH`

Admin handoff:

- `ADMIN_SETTER_ADDRESS`
- optional `ADMIN_PRIVATE_KEY`

## Manifest Shape

Generated manifests include:

- contract proxy addresses
- implementation addresses
- deposit/loan coin beacon address
- initial role ownership recorded at deployment time

The deploy script writes `deployments/og-testnet-staging.json` for testnet staging and `deployments/og-mainnet-prod.json` for mainnet prod by default. Other environments fall back to `deployments/<env>-<chainId>.json`.

## Reward Hook

`rewardContract` is a legacy Zerrow compatibility hook, not the Bond reward
system.

Bond production rewards are owned by the separate `bond-rewards` stack: offchain
accrual, review, root publication, Merkle/URD proof generation, user claims, and
claim reconciliation all live there. Zerrow lending contracts should not be used
as canonical reward accounting.

The deployment script still requires a nonzero hook address unless
`DEPLOY_MOCK_REWARD=1`, because `coinFactory` passes the address into new
deposit/loan coins and calls `factoryUsedRegister`. The hook must implement
`iRewardMini`, but it should be treated only as compatibility plumbing.

Operational rules:

- Do not fund the hook address.
- Do not expose the hook as a claim contract.
- Do not index hook state for Bond reward balances.
- Do not set a Merkle distributor or URD contract as `REWARD_CONTRACT_ADDRESS`.
- For deployments that use fully offchain Bond rewards, use a verified no-op
  `iRewardMini` implementation or the mock hook as a compatibility address.

## Notes

- Deployments intentionally start with the deployer key as the temporary protocol admin, because the deployer must finish contract wiring and market configuration before handing control to the long-lived admin.
- `lendingInterface` and `lstInterface` now support explicit admin handoff, so their upgrade authority can be transferred during the final handoff step instead of remaining stuck with the deployer.
- The example Redstone feed maps under `config/` are templates. Confirm feed addresses against the RedStone explorer before broadcasting market configuration on a real environment.
- The Galileo feed map includes the RedStone `0G/USD` testnet feed, so assets with `oracleFeedId: "0G"` can be priced from native `0G`.
