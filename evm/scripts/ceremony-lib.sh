#!/usr/bin/env bash
# Shared helpers for launch/seed/lock precheck and check scripts.
# shellcheck disable=SC2034

FAIL=0
ZERO="0x0000000000000000000000000000000000000000"
ok() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
warn() { printf '  WARN %s\n' "$1"; }
lc() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
uint() { printf '%s' "$1" | awk '{print $1}'; }
is_zero() { [[ "$(lc "$1")" = "$(lc "$ZERO")" ]]; }

ceremony_load() {
  local env_file="$1"
  CLUSTER="${2:-}"
  if [[ ! -f "$env_file" ]]; then
    echo "Missing $env_file" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a && . "$env_file" && set +a
  if [[ -z "$CLUSTER" ]]; then
    CLUSTER="${EVM_CLUSTER:-$(basename "$env_file")}"
    CLUSTER="${CLUSTER#.env.}"
  fi
  RPC="${RPC_URL:-${ANVIL_RPC_URL:-${ARBITRUM_RPC_URL:-${BASE_RPC_URL:-}}}}"
  if [[ -z "$RPC" ]]; then
    echo "RPC_URL missing in $env_file" >&2
    exit 1
  fi
  if [[ "$CLUSTER" = anvil ]]; then
    RECIPIENT_APPROVER="${RECIPIENT_APPROVER:-0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65}"
    BUYBACK_CALLERS="${BUYBACK_CALLERS:-0x71bE63f3384f5fb98995898A86B02Fb2426c5788}"
  fi
  ceremony_unset_empty
}

# Foundry vm.envAddress / envOr treat a blank export as set, then fail to parse it.
ceremony_unset_empty() {
  local k v
  for k in \
    QUOTE_TOKEN_ADDRESS PXT_ADDRESS PHOENIX_HOOK FEE_COLLECTOR PHOENIX_LAUNCHER PHOENIX_ORCHESTRATOR \
    ANTI_BOT_OPEN_SELL ANTI_BOT_SELLER OPEN_SELL_OPERATOR ANTI_BOT_OPERATOR LAUNCH_OWNER \
    POOL_CURRENCY0 POOL_CURRENCY1 POOL_MANAGER POOL_SWAP_TEST POOL_MODIFY_LIQUIDITY_TEST \
    POSITION_MANAGER UNIVERSAL_ROUTER NO_PENALTY_WALLET NO_PENALTY_WALLETS FEE_EXEMPT_WALLETS \
    DONATION_WALLET MARKETING_WALLET RECIPIENT_APPROVER BUYBACK_CALLERS; do
    eval "v=\${$k-}"
    if [[ -z "${v// }" ]]; then
      unset "$k"
    fi
  done
}

# Makefile includes evm/.env.anvil by default and exports it into every recipe.
# Clear those before sourcing evm/.env.base|arbitrum so live launches do not inherit
# Anvil OPEN_SELL_OPERATOR / POOL_SWAP_TEST / prior stack addresses.
ceremony_clear_inherited_cluster_env() {
  unset \
    OPEN_SELL_OPERATOR ANTI_BOT_OPERATOR ANTI_BOT_SELLER ANTI_BOT_OPEN_SELL \
    POOL_SWAP_TEST POOL_MODIFY_LIQUIDITY_TEST \
    PXT_ADDRESS PHOENIX_HOOK FEE_COLLECTOR PHOENIX_LAUNCHER PHOENIX_ORCHESTRATOR \
    POOL_CURRENCY0 POOL_CURRENCY1 LAUNCH_OWNER LAUNCH_SALT \
    ADMIN_ADDRESS PRIVATE_KEY DONATION_WALLET MARKETING_WALLET \
    FEE_EXEMPT_WALLETS NO_PENALTY_WALLETS NO_PENALTY_WALLET \
    RECIPIENT_APPROVER BUYBACK_CALLERS SELL_UNLOCK_TIMESTAMP \
    RPC_URL BASE_RPC_URL ARBITRUM_RPC_URL ANVIL_RPC_URL FORK_CHAIN_ID \
    POOL_MANAGER POSITION_MANAGER UNIVERSAL_ROUTER STATE_VIEW QUOTER PERMIT2 \
    QUOTE_TOKEN_ADDRESS QUOTE_DECIMALS LP_SEED_USDC_WHOLE LP_SEED_PXT_WHOLE \
    BUYBACK_RECYCLE_WIDTH_SPACINGS BUYBACK_MAX_SLIPPAGE_BPS SQRT_PRICE_X96 \
    EVM_CLUSTER HOOK_MODE USE_MOCK_USDC
}

need_rpc() {
  if ! CHAIN_ID=$(cast chain-id --rpc-url "$RPC" 2>/dev/null); then
    fail "RPC not reachable ($RPC)"
    [[ "$CLUSTER" = anvil ]] && echo "       Start the fork: make anvil-base-sepolia-fork"
    echo "FAILED"
    exit 1
  fi
  ok "RPC $RPC  chainId=$CHAIN_ID"
}

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

eq_addr() {
  local label="$1" got="$2" want="$3"
  if [[ "$(lc "$got")" != "$(lc "$want")" ]]; then
    fail "$label: got $got want $want"
  else
    ok "$label $got"
  fi
}

need_stack() {
  need_addr PXT_ADDRESS "${PXT_ADDRESS:-}"
  need_addr PHOENIX_HOOK "${PHOENIX_HOOK:-}"
  need_addr FEE_COLLECTOR "${FEE_COLLECTOR:-}"
  need_addr PHOENIX_ORCHESTRATOR "${PHOENIX_ORCHESTRATOR:-}"
  need_addr QUOTE_TOKEN_ADDRESS "${QUOTE_TOKEN_ADDRESS:-}"
  ORCH="${PHOENIX_ORCHESTRATOR:-}"
  PXT="${PXT_ADDRESS:-}"
  HOOK="${PHOENIX_HOOK:-}"
  FC="${FEE_COLLECTOR:-}"
  QUOTE="${QUOTE_TOKEN_ADDRESS:-}"
  if [[ -z "$ORCH" || -z "$PXT" || -z "$HOOK" || -z "$FC" ]]; then
    echo "FAILED — run make launch CLUSTER=$CLUSTER first"
    exit 1
  fi
}

owners_are_admin() {
  eq_addr "Pxt owner (admin/launchOwner)" "$PXT_OWNER" "$LAUNCH_OWNER"
  eq_addr "Hook owner (admin/launchOwner)" "$HOOK_OWNER" "$LAUNCH_OWNER"
  eq_addr "FeeCollector owner (admin/launchOwner)" "$FC_OWNER" "$LAUNCH_OWNER"
}

# Back-compat alias (old orch-owned ceremony).
owners_are_orchestrator() {
  owners_are_admin
}

owners_renounced() {
  local z
  z=$(lc "$ZERO")
  eq_addr "Pxt owner (renounced)" "$PXT_OWNER" "$z"
  eq_addr "Hook owner (renounced)" "$HOOK_OWNER" "$z"
  eq_addr "FeeCollector owner (renounced)" "$FC_OWNER" "$z"
}

load_state() {
  WIRED=$(cast call "$ORCH" "wired()(bool)" --rpc-url "$RPC")
  LOCKED=$(cast call "$ORCH" "locked()(bool)" --rpc-url "$RPC")
  SEEDED=$(cast call "$FC" "seedLiquidityAdded()(bool)" --rpc-url "$RPC")
  PHASE=$(cast call "$ORCH" "phase()(uint8)" --rpc-url "$RPC")
  LAUNCH_OWNER=$(cast call "$ORCH" "launchOwner()(address)" --rpc-url "$RPC")
  PXT_OWNER=$(cast call "$PXT" "owner()(address)" --rpc-url "$RPC")
  HOOK_OWNER=$(cast call "$HOOK" "owner()(address)" --rpc-url "$RPC")
  FC_OWNER=$(cast call "$FC" "owner()(address)" --rpc-url "$RPC")
}

need_signer_is_launch_owner() {
  if [[ -z "${PRIVATE_KEY:-}" ]]; then
    fail "PRIVATE_KEY missing"
    return 1
  fi
  DERIVED=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || true)
  if [[ -z "$DERIVED" ]]; then
    fail "PRIVATE_KEY is not a valid key"
    return 1
  fi
  eq_addr "signer is launchOwner" "$DERIVED" "$LAUNCH_OWNER"
}

position_liq() {
  local out
  out=$(cast call "$FC" "quoteBuyback()(uint256,uint128)" --rpc-url "$RPC")
  printf '%s\n' "$out" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]{4,}$/) last = $i } END { print last }'
}

finish() {
  local next="$1"
  echo ""
  if [[ "$FAIL" -ne 0 ]]; then
    echo "FAILED"
    exit 1
  fi
  echo "$next"
}
