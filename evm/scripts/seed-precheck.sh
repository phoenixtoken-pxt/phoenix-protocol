#!/usr/bin/env bash
# Ready-to-seed checks after `make launch`.
# Usage: seed-precheck.sh <env-file> [cluster]
set -euo pipefail
# shellcheck source=ceremony-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ceremony-lib.sh"

ceremony_load "${1:?usage: seed-precheck.sh <evm/.env.CLUSTER> [cluster]}" "${2:-}"
echo "seed-precheck  CLUSTER=$CLUSTER  env=$1"
need_rpc
need_stack
load_state
need_signer_is_launch_owner

[[ "$WIRED" = true ]] && ok "orchestrator.wired" || fail "orchestrator.wired=$WIRED — run make launch first"
[[ "$LOCKED" = false ]] && ok "orchestrator.locked=false" || fail "already locked"
owners_are_orchestrator

if [[ "$SEEDED" = true ]]; then
  fail "seedLiquidityAdded=true — already seeded; skip make seed"
else
  ok "seedLiquidityAdded=false"
fi

ORCH_PXT_BAL=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$ORCH" --rpc-url "$RPC")")
PXT_SEED=$(uint "$(cast call "$ORCH" "pxtSeed()(uint256)" --rpc-url "$RPC")")
echo "  …    orchestrator PXT $ORCH_PXT_BAL (pxtSeed=$PXT_SEED)"
if [[ "$ORCH_PXT_BAL" == 0 ]]; then
  fail "orchestrator PXT balance is 0"
else
  ok "orchestrator holds PXT for seed"
fi

USDC_SEED=$(uint "$(cast call "$ORCH" "usdcSeed()(uint256)" --rpc-url "$RPC")")
HAVE=$(uint "$(cast call "$QUOTE" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    launchOwner quote $HAVE (usdcSeed=$USDC_SEED)"
if [[ "$HAVE" -lt "$USDC_SEED" ]]; then
  fail "launchOwner quote < usdcSeed — cannot seed"
else
  ok "launchOwner holds enough quote for make seed"
fi

ETH_WEI=$(uint "$(cast balance "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    launchOwner ETH $ETH_WEI wei"
if [[ ${#ETH_WEI} -gt 16 ]]; then
  ok "ETH looks sufficient for gas"
elif [[ "$ETH_WEI" -ge 5000000000000000 ]]; then
  ok "ETH looks sufficient for gas"
else
  warn "ETH < 0.005 — seed may fail on gas"
fi

finish "READY — make seed CLUSTER=$CLUSTER"
