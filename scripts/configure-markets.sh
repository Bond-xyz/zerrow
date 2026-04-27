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
  SHARED_REGISTRY_ROOT
  LENDING_MANAGER_ADDRESS
  ORACLE_ADDRESS
  ASSETS_REGISTRY_PATH
  ORACLE_FEED_MAP_PATH
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

if [ -z "${ASSETS_REGISTRY_PATH:-}" ]; then
  if [ -z "${SHARED_REGISTRY_ROOT:-}" ]; then
    if [ -d "$PROJECT_ROOT/../bond-shared-registry" ]; then
      SHARED_REGISTRY_ROOT="$PROJECT_ROOT/../bond-shared-registry"
    elif [ -d "$PROJECT_ROOT/../../bond-shared-registry" ]; then
      SHARED_REGISTRY_ROOT="$PROJECT_ROOT/../../bond-shared-registry"
    else
      SHARED_REGISTRY_ROOT="$PROJECT_ROOT/../bond-shared-registry"
    fi
  fi

  if [ "$BOND_ENV" = "prod" ]; then
    ASSETS_REGISTRY_PATH="$SHARED_REGISTRY_ROOT/envs/og-mainnet-prod/assets.json"
  else
    ASSETS_REGISTRY_PATH="$SHARED_REGISTRY_ROOT/envs/og-testnet-staging/assets.json"
  fi
fi

if [ -z "${ORACLE_FEED_MAP_PATH:-}" ]; then
  if [ "$BOND_ENV" = "prod" ]; then
    ORACLE_FEED_MAP_PATH="$PROJECT_ROOT/config/redstone-feed-map.og-mainnet-prod.example.json"
  else
    ORACLE_FEED_MAP_PATH="$PROJECT_ROOT/config/redstone-feed-map.og-testnet-staging.example.json"
  fi
fi

if [ ! -f "$DEPLOYMENT_FILE" ]; then
  echo "Error: deployment file not found: $DEPLOYMENT_FILE"
  exit 1
fi

if [ ! -f "$ASSETS_REGISTRY_PATH" ]; then
  echo "Error: asset registry not found: $ASSETS_REGISTRY_PATH"
  exit 1
fi

if [ ! -f "$ORACLE_FEED_MAP_PATH" ]; then
  echo "Error: feed map not found: $ORACLE_FEED_MAP_PATH"
  exit 1
fi

INVALID_FEED_IDS="$(
  jq -r --slurpfile feedMap "$ORACLE_FEED_MAP_PATH" '
    [
      .assets[]
      | select((.enabled // false) and (.lending.enabled // false))
      | .oracleFeedId
    ] as $requiredFeedIds
    | ($feedMap[0].feeds // []) as $feeds
    | $requiredFeedIds[]
    | . as $feedId
    | ($feeds | map(select(.oracleFeedId == $feedId)) | .[0].feed // "") as $feed
    | select(
        ($feed | type) != "string"
        or ($feed | test("^0x[0-9a-fA-F]{40}$") | not)
        or ($feed | ascii_downcase) == "0x0000000000000000000000000000000000000000"
      )
    | $feedId
  ' "$ASSETS_REGISTRY_PATH" | sort -u
)"

if [ -n "$INVALID_FEED_IDS" ]; then
  echo "Error: feed map has pending, missing, or invalid feed addresses for lending-enabled assets:"
  printf '%s\n' "$INVALID_FEED_IDS" | sed 's/^/  - /'
  echo "Update ORACLE_FEED_MAP_PATH before running configure-markets."
  exit 1
fi

LENDING_MANAGER_ADDRESS="${LENDING_MANAGER_ADDRESS:-$(jq -r '.contracts.lendingManager // empty' "$DEPLOYMENT_FILE")}"
ORACLE_ADDRESS="${ORACLE_ADDRESS:-$(jq -r '.contracts.oracle // empty' "$DEPLOYMENT_FILE")}"

if ! [[ "$LENDING_MANAGER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Error: invalid LENDING_MANAGER_ADDRESS: ${LENDING_MANAGER_ADDRESS:-<empty>}"
  exit 1
fi

if ! [[ "$ORACLE_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Error: invalid ORACLE_ADDRESS: ${ORACLE_ADDRESS:-<empty>}"
  exit 1
fi

DEPLOYER="$(cast wallet address "$PRIVATE_KEY")"
SETTER_ADDRESS="$(cast call "$LENDING_MANAGER_ADDRESS" "setter()(address)" --rpc-url "$RPC_URL" 2>/dev/null || true)"

if ! [[ "$SETTER_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Error: failed to read lendingManager.setter()"
  exit 1
fi

if [ "$(printf '%s' "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$SETTER_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "Error: deployer is not the current lendingManager setter"
  echo "  deployer: $DEPLOYER"
  echo "  setter:   $SETTER_ADDRESS"
  exit 1
fi

cd "$PROJECT_ROOT"

echo "==========================================="
echo "Configure Zerrow Markets"
echo "Environment: $BOND_ENV"
echo "RPC:         $RPC_URL"
echo "Manifest:    $DEPLOYMENT_FILE"
echo "Assets:      $ASSETS_REGISTRY_PATH"
echo "Feeds:       $ORACLE_FEED_MAP_PATH"
echo "==========================================="

forge script script/ConfigureMarkets.s.sol:ConfigureMarkets \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PRIVATE_KEY" \
  -vvv
