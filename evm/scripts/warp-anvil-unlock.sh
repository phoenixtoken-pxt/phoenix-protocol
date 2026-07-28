#!/usr/bin/env bash
# Advance local Anvil block time to PXT sellUnlockTimestamp so wrap/swap work.
set -euo pipefail

ENV_FILE="${1:?env file required}"
# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

RPC="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
PXT="${PXT_ADDRESS:?PXT_ADDRESS missing in env}"

TS=$(cast call "$PXT" "sellUnlockTimestamp()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
NOW=$(cast block latest --field timestamp --rpc-url "$RPC" | awk '{print $1}')

if [[ "$NOW" -ge "$TS" ]]; then
  echo "Anvil already at or past sell unlock ($NOW >= $TS)"
  exit 0
fi

echo "Warping Anvil: $NOW -> $TS (sell unlock)"
cast rpc anvil_setNextBlockTimestamp "$TS" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
echo "Block timestamp now: $(cast block latest --field timestamp --rpc-url "$RPC" | awk '{print $1}')"
