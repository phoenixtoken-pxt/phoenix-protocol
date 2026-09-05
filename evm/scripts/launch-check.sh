#!/usr/bin/env bash
# Post-wire checks after `make launch` (before seed).
# Usage: launch-check.sh <env-file> [cluster]
set -euo pipefail

ENV_FILE="${1:?usage: launch-check.sh <evm/.env.CLUSTER> [cluster]}"
CLUSTER="${2:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run make launch first" >&2
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

echo "launch-check  CLUSTER=$CLUSTER  env=$ENV_FILE"

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
need_addr PHOENIX_HOOK "${PHOENIX_HOOK:-}"
need_addr FEE_COLLECTOR "${FEE_COLLECTOR:-}"
need_addr PHOENIX_ORCHESTRATOR "${PHOENIX_ORCHESTRATOR:-}"
need_addr PHOENIX_LAUNCHER "${PHOENIX_LAUNCHER:-}"
need_addr ANTI_BOT_OPEN_SELL "${ANTI_BOT_OPEN_SELL:-}"
need_addr QUOTE_TOKEN_ADDRESS "${QUOTE_TOKEN_ADDRESS:-}"
need_addr POOL_MANAGER "${POOL_MANAGER:-}"

ORCH="${PHOENIX_ORCHESTRATOR:-}"
PXT="${PXT_ADDRESS:-}"
HOOK="${PHOENIX_HOOK:-}"
FC="${FEE_COLLECTOR:-}"
if [[ -z "$ORCH" || -z "$PXT" || -z "$HOOK" || -z "$FC" ]]; then
  echo "FAILED — run make launch CLUSTER=$CLUSTER first"
  exit 1
fi

eq_addr() {
  local label="$1" got="$2" want="$3"
  if [[ "$(lc "$got")" != "$(lc "$want")" ]]; then
    fail "$label: got $got want $want"
  else
    ok "$label $got"
  fi
}

PXT_OWNER=$(cast call "$PXT" "owner()(address)" --rpc-url "$RPC")
HOOK_OWNER=$(cast call "$HOOK" "owner()(address)" --rpc-url "$RPC")
FC_OWNER=$(cast call "$FC" "owner()(address)" --rpc-url "$RPC")
eq_addr "Pxt owner (orchestrator)" "$PXT_OWNER" "$ORCH"
eq_addr "Hook owner (orchestrator)" "$HOOK_OWNER" "$ORCH"
eq_addr "FeeCollector owner (orchestrator)" "$FC_OWNER" "$ORCH"

ORCH_PXT=$(cast call "$ORCH" "pxt()(address)" --rpc-url "$RPC")
ORCH_HOOK=$(cast call "$ORCH" "hook()(address)" --rpc-url "$RPC")
ORCH_FC=$(cast call "$ORCH" "collector()(address)" --rpc-url "$RPC")
eq_addr "orchestrator.pxt" "$ORCH_PXT" "$PXT"
eq_addr "orchestrator.hook" "$ORCH_HOOK" "$HOOK"
eq_addr "orchestrator.collector" "$ORCH_FC" "$FC"

WIRED=$(cast call "$ORCH" "wired()(bool)" --rpc-url "$RPC")
LOCKED=$(cast call "$ORCH" "locked()(bool)" --rpc-url "$RPC")
SEEDED=$(cast call "$FC" "seedLiquidityAdded()(bool)" --rpc-url "$RPC")
[[ "$WIRED" = true ]] && ok "orchestrator.wired" || fail "orchestrator.wired=$WIRED"
[[ "$LOCKED" = false ]] && ok "orchestrator.locked=false" || fail "orchestrator.locked=$LOCKED (already locked?)"

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

ORCH_PXT_BAL=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$ORCH" --rpc-url "$RPC")")
SUPPLY=$(uint "$(cast call "$PXT" "TOTAL_SUPPLY()(uint256)" --rpc-url "$RPC")")
echo "  …    orchestrator PXT $ORCH_PXT_BAL / TOTAL_SUPPLY $SUPPLY"
if [[ "$ORCH_PXT_BAL" == 0 ]]; then
  fail "orchestrator PXT balance is 0"
else
  ok "orchestrator holds PXT (supply sits there until seed/lock)"
fi

OWNER="${ADMIN_ADDRESS:-}"
QUOTE="${QUOTE_TOKEN_ADDRESS:-}"
if [[ -n "$OWNER" && -n "$QUOTE" && "$SEEDED" != true ]]; then
  USDC_SEED=$(uint "$(cast call "$ORCH" "usdcSeed()(uint256)" --rpc-url "$RPC")")
  HAVE=$(uint "$(cast call "$QUOTE" "balanceOf(address)(uint256)" "$OWNER" --rpc-url "$RPC")")
  echo "  …    owner quote $HAVE (orchestrator.usdcSeed=$USDC_SEED)"
  if [[ "$HAVE" -lt "$USDC_SEED" ]]; then
    warn "owner quote < usdcSeed — OK for wire-only; fund before make seed"
  else
    ok "owner holds enough quote for make seed"
  fi
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "OK — next: make seed CLUSTER=$CLUSTER"
