#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

preserve_vars=(
  PRIVATE_KEY
  ADMIN_PRIVATE_KEY
  ADMIN_SETTER_ADDRESS
  RPC_URL
  OG_TESTNET_RPC_URL
  OG_MAINNET_RPC_URL
  BOND_ENV
  DEPLOYMENT_FILE
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

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required"
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "Error: cast is required"
  exit 1
fi

RPC_URL="${RPC_URL:-${OG_TESTNET_RPC_URL:-${OG_MAINNET_RPC_URL:-}}}"
BOND_ENV="${BOND_ENV:-staging}"

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "Error: PRIVATE_KEY is required"
  exit 1
fi

if [ -z "${ADMIN_SETTER_ADDRESS:-}" ]; then
  echo "Error: ADMIN_SETTER_ADDRESS is required"
  exit 1
fi

if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL is required"
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

LENDING_MANAGER="$(jq -r '.contracts.lendingManager // empty' "$DEPLOYMENT_FILE")"
LENDING_VAULTS="$(jq -r '.contracts.lendingVaults // empty' "$DEPLOYMENT_FILE")"
COIN_FACTORY="$(jq -r '.contracts.coinFactory // empty' "$DEPLOYMENT_FILE")"
ORACLE="$(jq -r '.contracts.oracle // empty' "$DEPLOYMENT_FILE")"
LENDING_INTERFACE="$(jq -r '.contracts.lendingInterface // empty' "$DEPLOYMENT_FILE")"
LST_INTERFACE="$(jq -r '.contracts.lstInterface // empty' "$DEPLOYMENT_FILE")"
BEACON="$(jq -r '.contracts.depositOrLoanCoinBeacon // empty' "$DEPLOYMENT_FILE")"

echo "Starting admin handoff..."
echo "  New admin: $ADMIN_SETTER_ADDRESS"
echo "  RPC:       $RPC_URL"

cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$LENDING_MANAGER" "transferSetter(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null
cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$LENDING_VAULTS" "transferSetter(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null
cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$COIN_FACTORY" "setPA(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null
cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$ORACLE" "transferSetter(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null
cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$LENDING_INTERFACE" "transferAdmin(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null

if [[ "$LST_INTERFACE" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$LST_INTERFACE" "transferAdmin(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null
fi

if [[ "$BEACON" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  cast send --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" "$BEACON" "transferOwnership(address)" "$ADMIN_SETTER_ADDRESS" >/dev/null
fi

if [ -n "${ADMIN_PRIVATE_KEY:-}" ]; then
  ADMIN_ADDRESS="$(cast wallet address "$ADMIN_PRIVATE_KEY")"
  if [ "$(printf '%s' "$ADMIN_ADDRESS" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$ADMIN_SETTER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "Error: ADMIN_PRIVATE_KEY resolves to $ADMIN_ADDRESS, expected $ADMIN_SETTER_ADDRESS"
    exit 1
  fi

  cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" "$LENDING_MANAGER" "acceptSetter(bool)" true >/dev/null
  cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" "$LENDING_VAULTS" "acceptSetter(bool)" true >/dev/null
  cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" "$COIN_FACTORY" "acceptPA(bool)" true >/dev/null
  cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" "$ORACLE" "acceptSetter(bool)" true >/dev/null
  cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" "$LENDING_INTERFACE" "acceptAdmin(bool)" true >/dev/null

  if [[ "$LST_INTERFACE" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    cast send --private-key "$ADMIN_PRIVATE_KEY" --rpc-url "$RPC_URL" "$LST_INTERFACE" "acceptAdmin(bool)" true >/dev/null
  fi

  echo "Admin handoff complete."
else
  echo "Admin handoff initiated."
  echo "Set ADMIN_PRIVATE_KEY to complete acceptSetter/acceptPA/acceptAdmin in one run."
fi
