#!/usr/bin/env bash
# Parse `make bootstrap-arbitrum` forge logs and merge deployed addresses into evm/.env.arbitrum.
# Usage: write-arbitrum-env.sh <forge-log> <evm-env-file>
set -euo pipefail

LOG="${1:?usage: write-arbitrum-env.sh <forge-log> <evm-env-file>}"
EVM_OUT="${2:?missing evm env path}"

POOL_MANAGER="0x360e68faccca8ca495c1b759fd9eee466db9fb32"
POSITION_MANAGER="0xd88f38f930b7952f2db2432cb002e7abbf3dd869"
UNIVERSAL_ROUTER="0xa51afafe0263b40edaef0df8781ea9aa03e381a3"
STATE_VIEW="0x76fd297e2d437cd7f76d50f01afe6160f86e9990"
QUOTER="0x3972c00f7ed4885e145823eb7c655375d275a1c5"
PERMIT2="0x000000000022D473030F116dDEE9F6B43aC78BA3"
USDC_DEFAULT="0xaf88d065e77c8cC2239327C5EDb3A432268e5831"

pick() {
  local key="$1"
  awk -v k="$key" '
    /^== Logs ==/ { inlogs=1; next }
    inlogs && /^## / { exit }
    inlogs && index($0, "  " k ": ") == 1 {
      sub(/^  [^:]+: /, "")
      print
      exit
    }
  ' "$LOG"
}

PXT="$(pick PXT)"
USDC="$(pick USDC)"
HOOK="$(pick PhoenixV4ReturnDeltaHook)"
COLLECTOR="$(pick PhoenixFeeCollector)"
DONATION="$(pick 'Donation wallet')"
MARKETING="$(pick 'Marketing wallet')"
ADMIN="$(pick Admin)"
CURRENCY0="$(pick currency0)"
CURRENCY1="$(pick currency1)"
ANTI_BOT="$(pick 'Anti-bot seller')"
ANTI_BOT_OPERATOR="$(pick 'Anti-bot operator (funds open)')"
SELL_UNLOCK="$(pick 'Sell unlock timestamp')"
OPEN_SELL="$(pick PhoenixAntiBotOpenSell)"
SWAP_TEST="$(pick PoolSwapTest)"

REQUIRED=(PXT USDC HOOK DONATION MARKETING ADMIN CURRENCY0 CURRENCY1 COLLECTOR OPEN_SELL SWAP_TEST)
for v in "${REQUIRED[@]}"; do
  if [[ -z "${!v}" ]]; then
    echo "write-arbitrum-env: missing ${v} in forge log" >&2
    exit 1
  fi
done

# Preserve secrets / RPC from existing env if present.
PRIVATE_KEY=""
ARBITRUM_RPC_URL="https://arb1.arbitrum.io/rpc"
ARBISCAN_API_KEY=""
if [[ -f "$EVM_OUT" ]]; then
  # shellcheck disable=SC1090
  set -a && . "$EVM_OUT" && set +a || true
fi

cat >"$EVM_OUT" <<EOF
# Auto-updated by make bootstrap-arbitrum — DO NOT COMMIT
EVM_CLUSTER=arbitrum
HOOK_MODE=return-delta
ARBITRUM_RPC_URL=${ARBITRUM_RPC_URL}
FORK_CHAIN_ID=42161
ARBISCAN_API_KEY=${ARBISCAN_API_KEY}

PRIVATE_KEY=${PRIVATE_KEY}
ADMIN_ADDRESS=${ADMIN}
DONATION_WALLET=${DONATION}
MARKETING_WALLET=${MARKETING}

PXT_ADDRESS=${PXT}
QUOTE_TOKEN_ADDRESS=${USDC:-$USDC_DEFAULT}
PHOENIX_HOOK=${HOOK}
FEE_COLLECTOR=${COLLECTOR}
POOL_CURRENCY0=${CURRENCY0}
POOL_CURRENCY1=${CURRENCY1}
POOL_FEE=0
POOL_TICK_SPACING=60
POOL_MANAGER=${POOL_MANAGER}
POSITION_MANAGER=${POSITION_MANAGER}
UNIVERSAL_ROUTER=${UNIVERSAL_ROUTER}
STATE_VIEW=${STATE_VIEW}
QUOTER=${QUOTER}
POOL_SWAP_TEST=${SWAP_TEST}
PERMIT2=${PERMIT2}
ANTI_BOT_SELLER=${ANTI_BOT:-$ADMIN}
ANTI_BOT_OPERATOR=${ANTI_BOT_OPERATOR:-$ADMIN}
OPEN_SELL_OPERATOR=${ANTI_BOT_OPERATOR:-$ADMIN}
ANTI_BOT_OPEN_SELL=${OPEN_SELL}
SELL_UNLOCK_TIMESTAMP=${SELL_UNLOCK}

USE_MOCK_USDC=false
QUOTE_DECIMALS=6
LP_SEED_USDC_WHOLE=20
LP_SEED_PXT_WHOLE=20000
BUYBACK_RECYCLE_WIDTH_SPACINGS=10
BUYBACK_MAX_SLIPPAGE_BPS=200
EOF
chmod 600 "$EVM_OUT"
echo "Wrote $EVM_OUT"
