#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VALID_TARGETS="lendingManager lendingVaults coinFactory oracle lendingInterface lstInterface depositOrLoanCoin lendingCoreAlgorithm"

usage() {
  cat <<EOF
Usage: $0 <target>

Upgrade a single Zerrow contract on a live deployment.

Targets:
  lendingManager       UUPS — requires setter key
  lendingVaults        UUPS — requires setter key
  coinFactory          UUPS — requires setPermissionAddress key
  oracle               UUPS — requires setter key
  lendingInterface     UUPS — requires admin key
  lstInterface         UUPS — requires admin key
  depositOrLoanCoin    Beacon — requires beacon owner key
  lendingCoreAlgorithm Non-proxy — requires setter key (deploys new + re-points manager)

Environment:
  PRIVATE_KEY          (required) key of the wallet authorized to upgrade the target
  RPC_URL              (required) chain RPC endpoint
  BOND_ENV             staging (default) or prod
  DEPLOYMENT_FILE      path to deployment manifest (auto-resolved from BOND_ENV if omitted)
  DRY_RUN              set to 1 to simulate without broadcasting

Example:
  PRIVATE_KEY=0x... RPC_URL=https://... BOND_ENV=prod $0 lendingManager
EOF
  exit 1
}

if [ $# -lt 1 ]; then
  usage
fi

TARGET="$1"

is_valid=false
for t in $VALID_TARGETS; do
  if [ "$t" = "$TARGET" ]; then
    is_valid=true
    break
  fi
done

if [ "$is_valid" = false ]; then
  echo "Error: unknown target '$TARGET'"
  echo "Valid targets: $VALID_TARGETS"
  exit 1
fi

preserve_vars=(
  PRIVATE_KEY
  RPC_URL
  OG_TESTNET_RPC_URL
  OG_MAINNET_RPC_URL
  BOND_ENV
  DEPLOYMENT_FILE
  DRY_RUN
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
DRY_RUN="${DRY_RUN:-0}"

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

if [ ! -f "$DEPLOYMENT_FILE" ]; then
  echo "Error: deployment file not found: $DEPLOYMENT_FILE"
  exit 1
fi

echo "==========================================="
echo "Upgrade Zerrow Contract"
echo "  Target:      $TARGET"
echo "  Environment: $BOND_ENV"
echo "  RPC:         $RPC_URL"
echo "  Manifest:    $DEPLOYMENT_FILE"
if [ "$DRY_RUN" = "1" ]; then
  echo "  Mode:        DRY RUN (simulation only)"
fi
echo "==========================================="

FORGE_ARGS=(
  script/UpgradeContract.s.sol:UpgradeContract
  --rpc-url "$RPC_URL"
  --private-key "$PRIVATE_KEY"
  -vvv
)

if [ "$DRY_RUN" != "1" ]; then
  FORGE_ARGS+=(--broadcast)
fi

cd "$PROJECT_ROOT"

UPGRADE_TARGET="$TARGET" DEPLOYMENT_FILE="$DEPLOYMENT_FILE" \
  forge script "${FORGE_ARGS[@]}"
