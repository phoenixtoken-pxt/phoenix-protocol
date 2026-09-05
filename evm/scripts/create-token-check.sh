#!/usr/bin/env bash
# Post Phase-1 checks after `make create-token` (before deploy-pool).
# Usage: create-token-check.sh <env-file> [cluster]
set -euo pipefail

ENV_FILE="${1:?usage: create-token-check.sh <evm/.env.CLUSTER> [cluster]}"
CLUSTER="${2:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run make create-token first" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

if [[ -z "$CLUSTER" ]]; then
  CLUSTER="${EVM_CLUSTER:-$(basename "$ENV_FILE")}"
  CLUSTER="${CLUSTER#.env.}"
fi

RPC="${RPC_URL:-${ANVIL_RPC_URL:-${ARBITRUM_RPC_URL:-${BASE_RPC_URL:-}}}}"
FAIL=0
ok() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
warn() { printf '  WARN %s\n' "$1"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
uint() { printf '%s' "$1" | awk '{print $1}'; }

echo "create-token-check  CLUSTER=$CLUSTER  env=$ENV_FILE"

if [[ -z "$RPC" ]]; then
  fail "RPC_URL missing"
  echo "FAILED"
  exit 1
fi

need_addr() {
  local name="$1"
  local addr="${2:-}"
  local code
  if [[ -z "$addr" ]]; then
    fail "$name missing in env"
    return 1
  fi
  code=$(cast code "$addr" --rpc-url "$RPC" 2>/dev/null || true)
  if [[ -z "$code" || "$code" = "0x" ]]; then
    fail "$name $addr has no code"
    return 1
  fi
  ok "$name $addr"
}

need_addr PXT_ADDRESS "${PXT_ADDRESS:-}"
need_addr PHOENIX_ORCHESTRATOR "${PHOENIX_ORCHESTRATOR:-}"
need_addr PHOENIX_LAUNCHER "${PHOENIX_LAUNCHER:-}"

ORCH="${PHOENIX_ORCHESTRATOR:-}"
PXT="${PXT_ADDRESS:-}"
ADMIN="${ADMIN_ADDRESS:-}"

eq_addr() {
  local label="$1" got="$2" want="$3"
  if [[ "$(lc "$got")" != "$(lc "$want")" ]]; then
    fail "$label: got $got want $want"
  else
    ok "$label $got"
  fi
}

PHASE=$(cast call "$ORCH" "phase()(uint8)" --rpc-url "$RPC")
LAUNCH_OWNER=$(cast call "$ORCH" "launchOwner()(address)" --rpc-url "$RPC")
PXT_OWNER=$(cast call "$PXT" "owner()(address)" --rpc-url "$RPC")
ORCH_PXT=$(cast call "$ORCH" "pxt()(address)" --rpc-url "$RPC")

# Phase enum: None=0 TokenCreated=1 ...
if [[ "$PHASE" = "1" ]]; then
  ok "phase=TokenCreated"
else
  fail "phase=$PHASE (want TokenCreated=1)"
fi

eq_addr "orchestrator.pxt" "$ORCH_PXT" "$PXT"
eq_addr "Pxt owner (admin)" "$PXT_OWNER" "$LAUNCH_OWNER"
if [[ -n "$ADMIN" ]]; then
  eq_addr "ADMIN_ADDRESS == launchOwner" "$ADMIN" "$LAUNCH_OWNER"
fi

ADMIN_BAL=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
SUPPLY=$(uint "$(cast call "$PXT" "TOTAL_SUPPLY()(uint256)" --rpc-url "$RPC")")
ORCH_BAL=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$ORCH" --rpc-url "$RPC")")
echo "  …    admin PXT $ADMIN_BAL / TOTAL_SUPPLY $SUPPLY"
echo "  …    orchestrator PXT $ORCH_BAL (should be 0)"

if [[ "$ORCH_BAL" != 0 ]]; then
  fail "orchestrator still holds PXT (old ceremony?)"
fi
if [[ "$ADMIN_BAL" == 0 ]]; then
  warn "admin PXT is 0 — already transferred treasury? OK if intentional before deploy-pool"
else
  ok "admin holds PXT (transfer treasury to MAIN before/after deploy-pool as needed)"
fi

if [[ -n "${PHOENIX_HOOK:-}" ]]; then
  warn "PHOENIX_HOOK already set — pool may already be deployed"
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "OK — next: transfer treasury if needed, then make deploy-pool CLUSTER=$CLUSTER"
