#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

preserve_vars=(
  PRIVATE_KEY
  RPC_URL
  OG_TESTNET_RPC_URL
  OG_MAINNET_RPC_URL
  BOND_ENV
  DEPLOYMENT_FILE
  W0G_ADDRESS
  REWARD_CONTRACT_ADDRESS
  DEPLOY_MOCK_REWARD
  RISK_ISOLATION_MODE_ACCEPT_ASSET
  NORMAL_HEALTH_FACTOR_BPS
  HOMOGENEOUS_HEALTH_FACTOR_BPS
  REWARD_DEPOSIT_TYPE
  REWARD_LOAN_TYPE
  ORACLE_MAX_STALENESS
  ST0G_ADDRESS
)

for var in "${preserve_vars[@]}"; do
  eval "EXTERNAL_${var}=\"\${${var}:-}\""
done

if [ -f "$PROJECT_ROOT/.env" ]; then
  set -a
  . "$PROJECT_ROOT/.env"
  set +a
fi

for var in "${preserve_vars[@]}"; do
  eval "value=\"\${EXTERNAL_${var}:-}\""
  if [ -n "$value" ]; then
    export "$var=$value"
  fi
done

RPC_URL="${RPC_URL:-${OG_TESTNET_RPC_URL:-${OG_MAINNET_RPC_URL:-}}}"
BOND_ENV="${BOND_ENV:-staging}"

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "Error: PRIVATE_KEY is required"
  exit 1
fi

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is required"
  exit 1
fi

if [ -z "${W0G_ADDRESS:-}" ]; then
  echo "Error: W0G_ADDRESS is required"
  exit 1
fi

if [ "${DEPLOY_MOCK_REWARD:-0}" != "1" ] && [ -z "${REWARD_CONTRACT_ADDRESS:-}" ]; then
  echo "Error: REWARD_CONTRACT_ADDRESS is required unless DEPLOY_MOCK_REWARD=1"
  exit 1
fi

cd "$PROJECT_ROOT"

echo "==========================================="
echo "Deploy Zerrow Protocol"
echo "Environment: $BOND_ENV"
echo "RPC:         $RPC_URL"
echo "==========================================="

forge script script/DeployProtocol.s.sol:DeployProtocol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  -vvv
