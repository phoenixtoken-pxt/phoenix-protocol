#!/usr/bin/env bash
# Post Phase-2 checks after `make deploy-pool` (before seed).
# Usage: deploy-pool-check.sh <env-file> [cluster]
set -euo pipefail
# shellcheck source=ceremony-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ceremony-lib.sh"

ceremony_load "${1:?usage: deploy-pool-check.sh <evm/.env.CLUSTER> [cluster]}" "${2:-}"
echo "deploy-pool-check  CLUSTER=$CLUSTER  env=$1"
need_rpc
need_stack
need_addr ANTI_BOT_OPEN_SELL "${ANTI_BOT_OPEN_SELL:-}"
need_addr POOL_MANAGER "${POOL_MANAGER:-}"
load_state

[[ "$WIRED" = true ]] && ok "orchestrator.wired (PoolConfigured+)" || fail "orchestrator.wired=$WIRED"
[[ "$LOCKED" = false ]] && ok "orchestrator.locked=false" || fail "orchestrator.locked=$LOCKED (already locked?)"
owners_are_admin

if [[ "$SEEDED" = true ]]; then
  warn "seedLiquidityAdded=true — LP already seeded; skip make seed"
else
  ok "seedLiquidityAdded=false (ready for make seed)"
fi

FC_ON_PXT=$(cast call "$PXT" "feeCollector()(address)" --rpc-url "$RPC")
PM_ON_PXT=$(cast call "$PXT" "poolManager()(address)" --rpc-url "$RPC")
SELLER=$(cast call "$PXT" "antiBotSeller()(address)" --rpc-url "$RPC")
eq_addr "pxt.feeCollector" "$FC_ON_PXT" "$FC"
eq_addr "pxt.poolManager" "$PM_ON_PXT" "$POOL_MANAGER"
eq_addr "pxt.antiBotSeller" "$SELLER" "$ANTI_BOT_OPEN_SELL"

PXT_SEED=$(uint "$(cast call "$ORCH" "pxtSeed()(uint256)" --rpc-url "$RPC")")
ADMIN_PXT=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    admin PXT $ADMIN_PXT (pxtSeed=$PXT_SEED)"
if [[ "$ADMIN_PXT" -lt "$PXT_SEED" ]]; then
  warn "admin PXT < pxtSeed — fund admin before make seed"
else
  ok "admin holds enough PXT for make seed"
fi

USDC_SEED=$(uint "$(cast call "$ORCH" "usdcSeed()(uint256)" --rpc-url "$RPC")")
HAVE=$(uint "$(cast call "$QUOTE" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    admin quote $HAVE (usdcSeed=$USDC_SEED)"
if [[ "$HAVE" -lt "$USDC_SEED" ]]; then
  warn "admin quote < usdcSeed — fund before make seed"
else
  ok "admin holds enough quote for make seed"
fi

finish "OK — next: make seed CLUSTER=$CLUSTER"
