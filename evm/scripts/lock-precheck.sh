#!/usr/bin/env bash
# Ready-to-lock checks after `make seed`.
# Usage: lock-precheck.sh <env-file> [cluster]
set -euo pipefail
# shellcheck source=ceremony-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ceremony-lib.sh"

ceremony_load "${1:?usage: lock-precheck.sh <evm/.env.CLUSTER> [cluster]}" "${2:-}"
echo "lock-precheck  CLUSTER=$CLUSTER  env=$1"
need_rpc
need_stack
load_state
need_signer_is_launch_owner

[[ "$WIRED" = true ]] && ok "orchestrator.wired" || fail "orchestrator.wired=$WIRED"
[[ "$LOCKED" = false ]] && ok "orchestrator.locked=false" || fail "already locked"
owners_are_orchestrator

if [[ "$SEEDED" = true ]]; then
  ok "seedLiquidityAdded=true"
else
  fail "seedLiquidityAdded=false — run make seed first"
fi

LIQ=$(position_liq)
echo "  …    positionLiquidity $LIQ"
if [[ "$LIQ" == 0 ]]; then
  fail "position liquidity is 0 (ZeroProtocolLiquidity)"
else
  ok "protocol LP is live"
fi

SLIP=$(uint "$(cast call "$FC" "maxBuybackSlippageBps()(uint16)" --rpc-url "$RPC")")
if [[ "$SLIP" == 0 ]]; then
  fail "maxBuybackSlippageBps=0"
else
  ok "maxBuybackSlippageBps=$SLIP"
fi

APPROVER="${RECIPIENT_APPROVER:-}"
if [[ -z "$APPROVER" ]]; then
  fail "RECIPIENT_APPROVER missing in env"
elif is_zero "$APPROVER"; then
  fail "RECIPIENT_APPROVER is zero"
elif [[ "$(lc "$APPROVER")" = "$(lc "$LAUNCH_OWNER")" ]]; then
  fail "RECIPIENT_APPROVER must not be launchOwner ($LAUNCH_OWNER)"
elif [[ "$(lc "$APPROVER")" = "$(lc "$ORCH")" ]]; then
  fail "RECIPIENT_APPROVER must not be the orchestrator"
else
  ok "RECIPIENT_APPROVER $APPROVER"
fi

CALLERS="${BUYBACK_CALLERS:-}"
if [[ -z "$CALLERS" ]]; then
  fail "BUYBACK_CALLERS missing (comma-separated, at least one)"
else
  ok "BUYBACK_CALLERS $CALLERS"
  IFS=',' read -r -a CALLER_ARR <<<"$CALLERS"
  APPLIED=0
  for c in "${CALLER_ARR[@]}"; do
    c="${c// /}"
    [[ -z "$c" ]] && continue
    if is_zero "$c" || [[ "$(lc "$c")" = "$(lc "$LAUNCH_OWNER")" ]] || [[ "$(lc "$c")" = "$(lc "$ORCH")" ]]; then
      warn "skipping invalid BUYBACK_CALLER $c (zero / owner / orchestrator)"
      continue
    fi
    APPLIED=$((APPLIED + 1))
    ok "buyback caller $c"
  done
  if [[ "$APPLIED" -lt 1 ]]; then
    fail "no valid BUYBACK_CALLERS (need at least one that is not owner/orchestrator)"
  fi
fi

finish "READY — make lock CLUSTER=$CLUSTER"
