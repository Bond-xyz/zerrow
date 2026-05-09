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
  MULTISIG_ADDRESS
  GUARDIAN_ADDRESS
  TIMELOCK_DELAY
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
  echo "Error: PRIVATE_KEY is required (current setter/deployer key)"
  exit 1
fi

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is required"
  exit 1
fi

if [ -z "${MULTISIG_ADDRESS:-}" ]; then
  echo "Error: MULTISIG_ADDRESS is required (proposer + executor on the timelock)"
  exit 1
fi

if [ -z "${GUARDIAN_ADDRESS:-}" ]; then
  echo "Error: GUARDIAN_ADDRESS is required (can emergency-pause without delay)"
  exit 1
fi

if [ -z "${DEPLOYMENT_FILE:-}" ]; then
  if [ "$BOND_ENV" = "prod" ]; then
    DEPLOYMENT_FILE="$PROJECT_ROOT/deployments/og-mainnet-prod.json"
  else
    DEPLOYMENT_FILE="$PROJECT_ROOT/deployments/og-testnet-staging.json"
  fi
fi

if [ ! -f "$DEPLOYMENT_FILE" ]; then
  echo "Error: deployment file not found: $DEPLOYMENT_FILE"
  exit 1
fi

DELAY_DISPLAY="${TIMELOCK_DELAY:-172800}"
DELAY_HOURS=$(( DELAY_DISPLAY / 3600 ))

echo "==========================================="
echo "Deploy Zerrow Timelock"
echo "  Environment: $BOND_ENV"
echo "  RPC:         $RPC_URL"
echo "  Multisig:    $MULTISIG_ADDRESS"
echo "  Guardian:    $GUARDIAN_ADDRESS"
echo "  Delay:       ${DELAY_HOURS}h (${DELAY_DISPLAY}s)"
echo "  Manifest:    $DEPLOYMENT_FILE"
echo "==========================================="

cd "$PROJECT_ROOT"

forge script script/DeployTimelock.s.sol:DeployTimelock \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  -vvv
