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
- `REWARD_CONTRACT_ADDRESS`

Optional deployment overrides:

- `BOND_ENV` (`staging` by default)
- `DEPLOYMENT_FILE`
- `DEPLOY_MOCK_REWARD=1`
- `RISK_ISOLATION_MODE_ACCEPT_ASSET`
- `NORMAL_HEALTH_FACTOR_BPS`
- `HOMOGENEOUS_HEALTH_FACTOR_BPS`
- `REWARD_DEPOSIT_TYPE`
- `REWARD_LOAN_TYPE`
- `ORACLE_MAX_STALENESS`
- `ST0G_ADDRESS`

Market configuration:

- `ASSETS_REGISTRY_PATH`
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

## Notes

- Deployments intentionally start with the deployer key as the temporary protocol admin, because the deployer must finish contract wiring and market configuration before handing control to the long-lived admin.
- `lendingInterface` and `lstInterface` now support explicit admin handoff, so their upgrade authority can be transferred during the final handoff step instead of remaining stuck with the deployer.
- The example Redstone feed maps under `config/` are templates. Replace any zero or pending feed addresses before broadcasting market configuration on a real environment.
- The Galileo feed map assumes RedStone will publish a `0G/USD` feed for testnet. Once that address is available, configure `oracleFeedId: "0G"` with the published feed so `W0G` can be priced from native `0G`.

## TODO Before Bond Deployment

- Update Bond's shared registry native wrapper entry from `wA0GI` to `W0G` and enable the intended `W0G` lending market before using this deployment lane.
