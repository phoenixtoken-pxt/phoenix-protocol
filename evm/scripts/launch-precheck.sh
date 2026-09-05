#!/usr/bin/env bash
# Ready-to-launch checks for evm/.env.$(CLUSTER).
# Usage: launch-precheck.sh <env-file> [cluster]
set -euo pipefail

ENV_FILE="${1:?usage: launch-precheck.sh <evm/.env.CLUSTER> [cluster]}"
CLUSTER="${2:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — copy the matching .example (or make launch CLUSTER=anvil to copy anvil)" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "$CLUSTER" ]]; then
  CLUSTER="${EVM_CLUSTER:-$(basename "$ENV_FILE")}"
  CLUSTER="${CLUSTER#.env.}"
fi
if [[ "$CLUSTER" = anvil && -f "$ROOT/.anvil-session.env" ]]; then
  # shellcheck disable=SC1091
  set -a && . "$ROOT/.anvil-session.env" && set +a
fi

RPC="${RPC_URL:-${ANVIL_RPC_URL:-${ARBITRUM_RPC_URL:-${BASE_RPC_URL:-}}}}"
FAIL=0
ok() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
warn() { printf '  WARN %s\n' "$1"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
uint() { printf '%s' "$1" | awk '{print $1}'; }

echo "launch-precheck  CLUSTER=$CLUSTER  env=$ENV_FILE"

if [[ -z "$RPC" ]]; then
  fail "RPC_URL missing"
  echo "FAILED"
  exit 1
fi

if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC" 2>/dev/null); then
  fail "RPC not reachable ($RPC)"
  if [[ "$CLUSTER" = anvil ]]; then
    echo "       Start the fork: make anvil-base-sepolia-fork"
  fi
  echo "FAILED"
  exit 1
fi
ok "RPC $RPC  chainId=$CHAIN_ID"

EXPECT_CHAIN="${FORK_CHAIN_ID:-}"
if [[ -z "$EXPECT_CHAIN" ]]; then
  case "$CLUSTER" in
    anvil) EXPECT_CHAIN=84532 ;;
    arbitrum) EXPECT_CHAIN=42161 ;;
    base) EXPECT_CHAIN=8453 ;;
  esac
fi
if [[ -n "$EXPECT_CHAIN" && "$CHAIN_ID" != "$EXPECT_CHAIN" ]]; then
  fail "chainId $CHAIN_ID != FORK_CHAIN_ID/expected $EXPECT_CHAIN"
else
  ok "chainId matches expected $EXPECT_CHAIN"
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  fail "PRIVATE_KEY missing"
else
  ok "PRIVATE_KEY set"
  DERIVED=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || true)
  if [[ -n "${ADMIN_ADDRESS:-}" && -n "$DERIVED" ]]; then
    if [[ "$(lc "$ADMIN_ADDRESS")" != "$(lc "$DERIVED")" ]]; then
      fail "ADMIN_ADDRESS $ADMIN_ADDRESS != key address $DERIVED"
    else
      ok "ADMIN_ADDRESS matches PRIVATE_KEY ($ADMIN_ADDRESS)"
    fi
  elif [[ -z "${ADMIN_ADDRESS:-}" ]]; then
    fail "ADMIN_ADDRESS missing"
  fi
fi

if [[ -z "${DONATION_WALLET:-}" || "$DONATION_WALLET" = "0x0000000000000000000000000000000000000000" ]]; then
  fail "DONATION_WALLET missing"
else
  ok "DONATION_WALLET $DONATION_WALLET"
fi
if [[ -z "${MARKETING_WALLET:-}" || "$MARKETING_WALLET" = "0x0000000000000000000000000000000000000000" ]]; then
  fail "MARKETING_WALLET missing"
else
  ok "MARKETING_WALLET $MARKETING_WALLET"
fi

UNLOCK="${SELL_UNLOCK_TIMESTAMP:-}"
NOW=$(date +%s)
if [[ -z "$UNLOCK" ]]; then
  fail "SELL_UNLOCK_TIMESTAMP missing (anvil: start the fork so .anvil-session.env is written)"
elif [[ "$UNLOCK" -le "$NOW" ]]; then
  fail "SELL_UNLOCK_TIMESTAMP $UNLOCK is not in the future (now=$NOW)"
else
  ok "SELL_UNLOCK_TIMESTAMP $UNLOCK is in the future"
fi

PM="${POOL_MANAGER:-}"
if [[ -z "$PM" ]]; then
  fail "POOL_MANAGER missing"
else
  PM_CODE=$(cast code "$PM" --rpc-url "$RPC" 2>/dev/null || true)
  if [[ -z "$PM_CODE" || "$PM_CODE" = "0x" ]]; then
    fail "POOL_MANAGER $PM has no code (wrong network?)"
  else
    ok "POOL_MANAGER $PM has code"
  fi
fi

ADMIN="${ADMIN_ADDRESS:-}"
if [[ -n "$ADMIN" ]]; then
  ETH_WEI=$(uint "$(cast balance "$ADMIN" --rpc-url "$RPC")")
  echo "  …    ETH balance $ETH_WEI wei"
  if [[ ${#ETH_WEI} -gt 16 ]]; then
    ok "ETH looks sufficient for gas"
  elif [[ "$ETH_WEI" -lt 5000000000000000 ]]; then
    warn "ETH < 0.005 — launch may fail on gas"
  else
    ok "ETH looks sufficient for gas"
  fi
fi

QUOTE="${QUOTE_TOKEN_ADDRESS:-}"
SEED_WHOLE="${LP_SEED_USDC_WHOLE:-20}"
DEC="${QUOTE_DECIMALS:-6}"
if [[ "$CLUSTER" = anvil ]]; then
  ok "anvil: mock USDC is minted at launch (no pre-fund needed)"
elif [[ -z "$QUOTE" ]]; then
  fail "QUOTE_TOKEN_ADDRESS missing (required on live)"
else
  QCODE=$(cast code "$QUOTE" --rpc-url "$RPC" 2>/dev/null || true)
  if [[ -z "$QCODE" || "$QCODE" = "0x" ]]; then
    fail "QUOTE_TOKEN_ADDRESS $QUOTE has no code"
  else
    ok "QUOTE_TOKEN_ADDRESS $QUOTE has code"
  fi
  # Create-token does not spend quote — USDC is required only for make seed.
  # Soft-warn here; seed-precheck hard-fails if underfunded.
  if [[ -n "$ADMIN" ]]; then
    unit=1
    i=0
    while [[ "$i" -lt "$DEC" ]]; do
      unit=$((unit * 10))
      i=$((i + 1))
    done
    NEED=$((SEED_WHOLE * unit))
    HAVE=$(uint "$(cast call "$QUOTE" "balanceOf(address)(uint256)" "$ADMIN" --rpc-url "$RPC")")
    echo "  …    quote balance $HAVE (optional until seed; LP_SEED_USDC_WHOLE=$SEED_WHOLE → $NEED raw)"
    if [[ "$HAVE" -lt "$NEED" ]]; then
      warn "admin quote < planned LP seed — OK for create-token; fund before make seed"
    else
      ok "admin holds enough quote for later seed"
    fi
  fi
fi

# Only trust PHOENIX_ORCHESTRATOR from this env file — Makefile may export
# evm/.env.anvil into the recipe and falsely trip this on CLUSTER=base.
ORCH_FROM_FILE=$(grep -E '^PHOENIX_ORCHESTRATOR=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)
ORCH_FROM_FILE="${ORCH_FROM_FILE//$'\r'/}"
if [[ -n "$ORCH_FROM_FILE" ]]; then
  OCODE=$(cast code "$ORCH_FROM_FILE" --rpc-url "$RPC" 2>/dev/null || true)
  if [[ -n "$OCODE" && "$OCODE" != "0x" ]]; then
    warn "PHOENIX_ORCHESTRATOR already deployed at $ORCH_FROM_FILE — clear it (or new LAUNCH_SALT) for a fresh create-token"
  else
    warn "PHOENIX_ORCHESTRATOR is set in $ENV_FILE but has no code on this RPC (stale?)"
  fi
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "FAILED — fix the items above before make create-token CLUSTER=$CLUSTER"
  exit 1
fi
echo "READY — make create-token CLUSTER=$CLUSTER"
