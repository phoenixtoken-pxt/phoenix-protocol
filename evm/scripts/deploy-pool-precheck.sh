#!/usr/bin/env bash
# Ready-to-deploy-pool checks after `make create-token` (before broadcast).
# Validates LP_SEED_* ratio → implied USDC-per-PXT spot (TARGET_SPOT_PRICE).
# Usage: deploy-pool-precheck.sh <env-file> [cluster]
set -euo pipefail
# shellcheck source=ceremony-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/ceremony-lib.sh"

ceremony_load "${1:?usage: deploy-pool-precheck.sh <evm/.env.CLUSTER> [cluster]}" "${2:-}"
echo "deploy-pool-precheck  CLUSTER=$CLUSTER  env=$1"

need_rpc
need_addr "PXT_ADDRESS" "${PXT_ADDRESS:-}"
need_addr "PHOENIX_ORCHESTRATOR" "${PHOENIX_ORCHESTRATOR:-}"
need_addr "PHOENIX_LAUNCHER" "${PHOENIX_LAUNCHER:-}"
need_addr "POOL_MANAGER" "${POOL_MANAGER:-}"
need_addr "QUOTE_TOKEN_ADDRESS" "${QUOTE_TOKEN_ADDRESS:-}"

ORCH="${PHOENIX_ORCHESTRATOR}"
PXT="${PXT_ADDRESS}"
QUOTE="${QUOTE_TOKEN_ADDRESS}"
ADMIN="${ADMIN_ADDRESS:-}"

PHASE=$(cast call "$ORCH" "phase()(uint8)" --rpc-url "$RPC")
LAUNCH_OWNER=$(cast call "$ORCH" "launchOwner()(address)" --rpc-url "$RPC")
# Phase: None=0 TokenCreated=1 PoolContractsDeployed=2 PoolConfigured=3 Seeded=4 Locked=5
case "$PHASE" in
  1) ok "phase=TokenCreated (ready for deploy-pool)" ;;
  2) warn "phase=PoolContractsDeployed — deploy-pool will resume configure/init" ;;
  3) fail "phase=PoolConfigured — pool already initialized; skip deploy-pool" ;;
  4) fail "phase=Seeded — already past deploy-pool" ;;
  5) fail "phase=Locked — ceremony finished" ;;
  *) fail "phase=$PHASE (want TokenCreated=1)" ;;
esac

PXT_OWNER=$(cast call "$PXT" "owner()(address)" --rpc-url "$RPC")
if [[ "$(lc "$PXT_OWNER")" != "$(lc "$LAUNCH_OWNER")" ]]; then
  fail "Pxt owner $PXT_OWNER != launchOwner $LAUNCH_OWNER"
else
  ok "Pxt owner == launchOwner"
fi
if [[ -n "$ADMIN" && "$(lc "$ADMIN")" != "$(lc "$LAUNCH_OWNER")" ]]; then
  fail "ADMIN_ADDRESS $ADMIN != launchOwner $LAUNCH_OWNER"
elif [[ -n "$ADMIN" ]]; then
  ok "ADMIN_ADDRESS == launchOwner"
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  fail "PRIVATE_KEY missing"
else
  DERIVED=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || true)
  if [[ -n "$DERIVED" && "$(lc "$DERIVED")" != "$(lc "$LAUNCH_OWNER")" ]]; then
    fail "PRIVATE_KEY address $DERIVED != launchOwner $LAUNCH_OWNER"
  else
    ok "PRIVATE_KEY matches launchOwner"
  fi
fi

PXT_WHOLE="${LP_SEED_PXT_WHOLE:-}"
USDC_WHOLE="${LP_SEED_USDC_WHOLE:-}"
if [[ -z "$PXT_WHOLE" || -z "$USDC_WHOLE" ]]; then
  fail "LP_SEED_PXT_WHOLE / LP_SEED_USDC_WHOLE missing"
else
  ok "LP_SEED_PXT_WHOLE=$PXT_WHOLE  LP_SEED_USDC_WHOLE=$USDC_WHOLE"
fi

QUOTE_DEC="${QUOTE_DECIMALS:-6}"
PXT_DEC=$(cast call "$PXT" "decimals()(uint8)" --rpc-url "$RPC" 2>/dev/null || echo 6)
PXT_DEC=$(uint "$PXT_DEC")

TARGET="${TARGET_SPOT_PRICE:-}"
# shellcheck disable=SC2034
PRICE_INFO="$(
  PXT_WHOLE="$PXT_WHOLE" USDC_WHOLE="$USDC_WHOLE" PXT_DEC="$PXT_DEC" QUOTE_DEC="$QUOTE_DEC" \
  PXT="$PXT" QUOTE="$QUOTE" TARGET="$TARGET" python3 - <<'PY'
import os, sys
from decimal import Decimal, getcontext
getcontext().prec = 80

pxt_w = Decimal(os.environ["PXT_WHOLE"])
usdc_w = Decimal(os.environ["USDC_WHOLE"])
pxt_dec = int(os.environ["PXT_DEC"])
q_dec = int(os.environ["QUOTE_DEC"])
pxt = os.environ["PXT"].lower()
quote = os.environ["QUOTE"].lower()
target = os.environ.get("TARGET", "").strip()

if pxt_w <= 0 or usdc_w <= 0:
    print("FAIL zero seed")
    sys.exit(2)

pxt_raw = int(pxt_w * (10 ** pxt_dec))
usdc_raw = int(usdc_w * (10 ** q_dec))
# USDC per 1 PXT (human), same as raw ratio when decimals match
implied = (usdc_w / pxt_w)
print(f"IMPLIED {implied}")
print(f"PXT_RAW {pxt_raw}")
print(f"USDC_RAW {usdc_raw}")

# Match PhoenixLaunchMath.sqrtPriceForSpot / encodeSqrtRatioX96
if int(pxt, 16) < int(quote, 16):
    amount0, amount1 = pxt_raw, usdc_raw
    order = "PXT=token0"
else:
    amount0, amount1 = usdc_raw, pxt_raw
    order = "USDC=token0"
print(f"ORDER {order}")

ratio_x192 = (amount1 << 192) // amount0

def isqrt(n: int) -> int:
    if n == 0:
        return 0
    x = n
    y = (x + 1) // 2
    while y < x:
        x = y
        y = (x + n // x) // 2
    return x

sqrt_x96 = isqrt(ratio_x192)
print(f"SQRT {sqrt_x96}")

if target:
    t = Decimal(target)
    # relative tolerance 1e-12 or absolute 1e-18
    ok = abs(implied - t) <= max(Decimal("1e-18"), abs(t) * Decimal("1e-12"))
    print(f"TARGET {t}")
    print(f"MATCH {'yes' if ok else 'no'}")
    if not ok:
        sys.exit(3)
PY
)" || {
  fail "LP_SEED price math failed (check LP_SEED_* / TARGET_SPOT_PRICE)"
  finish "FAILED deploy-pool-precheck"
  exit 1
}

IMPLIED=$(printf '%s\n' "$PRICE_INFO" | awk '/^IMPLIED/{print $2}')
SQRT=$(printf '%s\n' "$PRICE_INFO" | awk '/^SQRT/{print $2}')
ORDER=$(printf '%s\n' "$PRICE_INFO" | awk '/^ORDER/{print $2}')
PXT_RAW=$(printf '%s\n' "$PRICE_INFO" | awk '/^PXT_RAW/{print $2}')
USDC_RAW=$(printf '%s\n' "$PRICE_INFO" | awk '/^USDC_RAW/{print $2}')
MATCH=$(printf '%s\n' "$PRICE_INFO" | awk '/^MATCH/{print $2}')

ok "implied spot ≈ $IMPLIED USDC per PXT ($ORDER)"
echo "  …    seed raw PXT=$PXT_RAW  USDC=$USDC_RAW"
echo "  …    sqrtPriceX96 (from seed ratio) $SQRT"

if [[ -n "$TARGET" ]]; then
  if [[ "$MATCH" = yes ]]; then
    ok "TARGET_SPOT_PRICE=$TARGET matches LP_SEED ratio"
  else
    fail "TARGET_SPOT_PRICE=$TARGET != implied $IMPLIED from LP_SEED_*"
  fi
else
  warn "TARGET_SPOT_PRICE unset — set e.g. TARGET_SPOT_PRICE=0.000005 to enforce"
fi

# Gas / balances (informational for deploy-pool; seed amounts needed later)
ETH_WEI=$(uint "$(cast balance "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    launchOwner ETH $ETH_WEI wei"
if [[ ${#ETH_WEI} -gt 16 ]] || [[ "$ETH_WEI" -ge 3000000000000000 ]]; then
  ok "ETH looks sufficient for deploy-pool gas"
else
  warn "ETH < ~0.003 — deploy-pool may fail on gas"
fi

HAVE_USDC=$(uint "$(cast call "$QUOTE" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    launchOwner USDC raw $HAVE_USDC (need $USDC_RAW by seed; not required for deploy-pool)"
ADMIN_PXT=$(uint "$(cast call "$PXT" "balanceOf(address)(uint256)" "$LAUNCH_OWNER" --rpc-url "$RPC")")
echo "  …    launchOwner PXT raw $ADMIN_PXT (need $PXT_RAW by seed; not required for deploy-pool)"
if [[ "$ADMIN_PXT" -lt "$PXT_RAW" ]] || [[ "$HAVE_USDC" -lt "$USDC_RAW" ]]; then
  warn "admin lacks full LP_SEED balances — OK for deploy-pool; fund before make seed"
else
  ok "admin already holds full LP_SEED balances"
fi

if [[ -n "${PHOENIX_HOOK:-}" ]]; then
  warn "PHOENIX_HOOK already in env — confirm you intend to resume/redeploy carefully"
fi

finish "READY — make deploy-pool CLUSTER=$CLUSTER (spot from LP_SEED ratio${TARGET:+, target $TARGET})"
