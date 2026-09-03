#!/usr/bin/env bash
# Post-lock checks after `make lock`.
# Usage: lock-check.sh <env-file> [cluster]
set -euo pipefail
# shellcheck source=ceremony-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ceremony-lib.sh"

ceremony_load "${1:?usage: lock-check.sh <evm/.env.CLUSTER> [cluster]}" "${2:-}"
echo "lock-check  CLUSTER=$CLUSTER  env=$1"
need_rpc
need_stack
load_state

[[ "$WIRED" = true ]] && ok "orchestrator.wired" || fail "orchestrator.wired=$WIRED"
[[ "$LOCKED" = true ]] && ok "orchestrator.locked=true" || fail "orchestrator.locked=$LOCKED — run make lock first"
owners_renounced

APPROVER="${RECIPIENT_APPROVER:-}"
if [[ -z "$APPROVER" ]]; then
  fail "RECIPIENT_APPROVER missing in env (needed to check roles)"
else
  ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
  APPROVER_ROLE=$(cast keccak "RECIPIENT_APPROVER_ROLE")
  BUYBACK_ROLE=$(cast keccak "BUYBACK_EXECUTOR_APPROVER_ROLE")

  PXT_ADMIN=$(cast call "$PXT" "hasRole(bytes32,address)(bool)" "$ADMIN_ROLE" "$APPROVER" --rpc-url "$RPC")
  PXT_APPR=$(cast call "$PXT" "hasRole(bytes32,address)(bool)" "$APPROVER_ROLE" "$APPROVER" --rpc-url "$RPC")
  ORCH_ADMIN=$(cast call "$PXT" "hasRole(bytes32,address)(bool)" "$ADMIN_ROLE" "$ORCH" --rpc-url "$RPC")
  ORCH_APPR=$(cast call "$PXT" "hasRole(bytes32,address)(bool)" "$APPROVER_ROLE" "$ORCH" --rpc-url "$RPC")
  [[ "$PXT_ADMIN" = true ]] && ok "Pxt DEFAULT_ADMIN_ROLE on RECIPIENT_APPROVER" || fail "Pxt DEFAULT_ADMIN_ROLE not on RECIPIENT_APPROVER"
  [[ "$PXT_APPR" = true ]] && ok "Pxt RECIPIENT_APPROVER_ROLE on RECIPIENT_APPROVER" || fail "Pxt RECIPIENT_APPROVER_ROLE not on RECIPIENT_APPROVER"
  [[ "$ORCH_ADMIN" = false ]] && ok "orchestrator no longer Pxt admin" || fail "orchestrator still Pxt DEFAULT_ADMIN_ROLE"
  [[ "$ORCH_APPR" = false ]] && ok "orchestrator no longer Pxt recipient-approver" || fail "orchestrator still RECIPIENT_APPROVER_ROLE"

  FC_ADMIN=$(cast call "$FC" "hasRole(bytes32,address)(bool)" "$ADMIN_ROLE" "$APPROVER" --rpc-url "$RPC")
  FC_BB=$(cast call "$FC" "hasRole(bytes32,address)(bool)" "$BUYBACK_ROLE" "$APPROVER" --rpc-url "$RPC")
  [[ "$FC_ADMIN" = true ]] && ok "FeeCollector DEFAULT_ADMIN_ROLE on RECIPIENT_APPROVER" || fail "FeeCollector DEFAULT_ADMIN_ROLE not on RECIPIENT_APPROVER"
  [[ "$FC_BB" = true ]] && ok "FeeCollector BUYBACK_EXECUTOR_APPROVER_ROLE on RECIPIENT_APPROVER" || fail "FeeCollector buyback-approver role not on RECIPIENT_APPROVER"
fi

ORCH_STILL=$(cast call "$FC" "isAuthorizedBuybackCaller(address)(bool)" "$ORCH" --rpc-url "$RPC")
[[ "$ORCH_STILL" = false ]] && ok "orchestrator is not a buyback caller" || fail "orchestrator still isAuthorizedBuybackCaller"

CALLERS="${BUYBACK_CALLERS:-}"
if [[ -n "$CALLERS" ]]; then
  IFS=',' read -r -a CALLER_ARR <<<"$CALLERS"
  for c in "${CALLER_ARR[@]}"; do
    c="${c// /}"
    [[ -z "$c" || "$(lc "$c")" = "$(lc "$LAUNCH_OWNER")" || "$(lc "$c")" = "$(lc "$ORCH")" ]] && continue
    AUTH=$(cast call "$FC" "isAuthorizedBuybackCaller(address)(bool)" "$c" --rpc-url "$RPC")
    [[ "$AUTH" = true ]] && ok "buyback caller authorized $c" || fail "buyback caller not authorized $c"
  done
fi

ORCH_PXT_BAL=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$ORCH" --rpc-url "$RPC")")
echo "  …    orchestrator leftover PXT $ORCH_PXT_BAL"
if [[ "$ORCH_PXT_BAL" == 0 ]]; then
  ok "orchestrator PXT swept to launchOwner"
else
  fail "orchestrator still holds PXT after lock"
fi

SEEDED=$(cast call "$FC" "seedLiquidityAdded()(bool)" --rpc-url "$RPC")
[[ "$SEEDED" = true ]] && ok "protocol LP still seeded" || fail "seedLiquidityAdded=false after lock"

finish "OK — stack locked. Roles on RECIPIENT_APPROVER."
