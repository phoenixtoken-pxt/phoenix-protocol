#!/usr/bin/env bash
# Post-seed checks after `make seed` (before lock).
# Usage: seed-check.sh <env-file> [cluster]
set -euo pipefail
# shellcheck source=ceremony-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ceremony-lib.sh"

ceremony_load "${1:?usage: seed-check.sh <evm/.env.CLUSTER> [cluster]}" "${2:-}"
echo "seed-check  CLUSTER=$CLUSTER  env=$1"
need_rpc
need_stack
load_state

[[ "$WIRED" = true ]] && ok "orchestrator.wired" || fail "orchestrator.wired=$WIRED"
[[ "$LOCKED" = false ]] && ok "orchestrator.locked=false" || fail "already locked"
owners_are_orchestrator

if [[ "$SEEDED" = true ]]; then
  ok "seedLiquidityAdded=true"
else
  fail "seedLiquidityAdded=false — run make seed first"
fi

POOL_OK=$(cast call "$FC" "poolConfigured()(bool)" --rpc-url "$RPC")
[[ "$POOL_OK" = true ]] && ok "poolConfigured" || fail "poolConfigured=false"

LIQ=$(position_liq)
echo "  …    positionLiquidity $LIQ"
if [[ "$LIQ" == 0 ]]; then
  fail "position liquidity is 0"
else
  ok "protocol LP is live"
fi

SLIP=$(uint "$(cast call "$FC" "maxBuybackSlippageBps()(uint16)" --rpc-url "$RPC")")
if [[ "$SLIP" == 0 ]]; then
  fail "maxBuybackSlippageBps=0"
else
  ok "maxBuybackSlippageBps=$SLIP"
fi

HAVE=$(uint "$(cast call "$QUOTE" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    launchOwner quote left $HAVE"

finish "OK — next: make lock-precheck CLUSTER=$CLUSTER then make lock CLUSTER=$CLUSTER"
