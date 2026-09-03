#!/usr/bin/env bash
# Verify Arbitrum One deployments on Arbiscan (Etherscan V2 API).
# Usage: verify-arbitrum.sh [evm/.env.arbitrum]
# Requires: ARBISCAN_API_KEY or ETHERSCAN_API_KEY in the env file / environment.
#
# Launcher path: Pxt / hook / FeeCollector constructors take the orchestrator as admin,
# not the EOA. Mine hook with operator = OPEN_SELL_OPERATOR (ANTI_BOT_SELLER env at wire).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT/.env.arbitrum}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run make launch first" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

API_KEY="${ARBISCAN_API_KEY:-${ETHERSCAN_API_KEY:-}}"
if [[ -z "$API_KEY" ]]; then
  echo "Set ARBISCAN_API_KEY (or ETHERSCAN_API_KEY) in $ENV_FILE" >&2
  echo "Get a key at https://etherscan.io/apidashboard (V2 works for Arbitrum)" >&2
  exit 1
fi

: "${PXT_ADDRESS:?}"
: "${PHOENIX_HOOK:?}"
: "${FEE_COLLECTOR:?}"
: "${POOL_SWAP_TEST:?}"
: "${ANTI_BOT_OPEN_SELL:?}"
: "${PHOENIX_ORCHESTRATOR:?}"
: "${ADMIN_ADDRESS:?}"
: "${DONATION_WALLET:?}"
: "${MARKETING_WALLET:?}"
: "${SELL_UNLOCK_TIMESTAMP:?}"
: "${POOL_MANAGER:?}"

HOOK_CTOR_THIRD="${OPEN_SELL_OPERATOR:-${ANTI_BOT_OPERATOR:-$ADMIN_ADDRESS}}"
OPEN_SELL_OPERATOR="${OPEN_SELL_OPERATOR:-$ADMIN_ADDRESS}"
ORCH="$PHOENIX_ORCHESTRATOR"

CHAIN=42161
VERIFY_COMMON=(--chain "$CHAIN" --etherscan-api-key "$API_KEY" --watch --compiler-version "0.8.26")

cd "$ROOT"

verify_one() {
  local addr="$1"
  local contract="$2"
  shift 2
  echo ""
  echo "=== Verifying $contract @ $addr ==="
  if forge verify-contract "$addr" "$contract" "${VERIFY_COMMON[@]}" "$@"; then
    echo "OK: $contract"
  else
    echo "FAILED: $contract (may already be verified — check Arbiscan)" >&2
    return 1
  fi
}

FAIL=0

# Pxt(orchestrator, donation, marketing, sellUnlock)
ARGS=$(cast abi-encode "constructor(address,address,address,uint256)" \
  "$ORCH" "$DONATION_WALLET" "$MARKETING_WALLET" "$SELL_UNLOCK_TIMESTAMP")
verify_one "$PXT_ADDRESS" "src/core/Pxt.sol:Pxt" --constructor-args "$ARGS" || FAIL=1

# PoolSwapTest(poolManager)
ARGS=$(cast abi-encode "constructor(address)" "$POOL_MANAGER")
verify_one "$POOL_SWAP_TEST" "lib/v4-core/src/test/PoolSwapTest.sol:PoolSwapTest" --constructor-args "$ARGS" || FAIL=1

# PhoenixV4ReturnDeltaHook(manager, pxt, operator, orchestrator)
ARGS=$(cast abi-encode "constructor(address,address,address,address)" \
  "$POOL_MANAGER" "$PXT_ADDRESS" "$HOOK_CTOR_THIRD" "$ORCH")
verify_one "$PHOENIX_HOOK" "src/return-delta/PhoenixV4ReturnDeltaHook.sol:PhoenixV4ReturnDeltaHook" \
  --constructor-args "$ARGS" || FAIL=1

# PhoenixFeeCollector(poolManager, pxt, donation, marketing, orchestrator)
ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" \
  "$POOL_MANAGER" "$PXT_ADDRESS" "$DONATION_WALLET" "$MARKETING_WALLET" "$ORCH")
verify_one "$FEE_COLLECTOR" "src/fee/PhoenixFeeCollector.sol:PhoenixFeeCollector" \
  --constructor-args "$ARGS" || FAIL=1

# PhoenixAntiBotOpenSell(pxt, swapRouter, operator)
ARGS=$(cast abi-encode "constructor(address,address,address)" \
  "$PXT_ADDRESS" "$POOL_SWAP_TEST" "$OPEN_SELL_OPERATOR")
verify_one "$ANTI_BOT_OPEN_SELL" "script/PhoenixAntiBotOpenSell.sol:PhoenixAntiBotOpenSell" \
  --constructor-args "$ARGS" || FAIL=1

if [[ -n "${PHOENIX_LAUNCHER:-}" && -n "${PHOENIX_PXT_DEPLOYER:-}" && -n "${PHOENIX_HOOK_DEPLOYER:-}" \
  && -n "${PHOENIX_COLLECTOR_DEPLOYER:-}" && -n "${PHOENIX_OPEN_SELL_DEPLOYER:-}" ]]; then
  ARGS=$(cast abi-encode "constructor(address,address,address,address)" \
    "$PHOENIX_PXT_DEPLOYER" "$PHOENIX_HOOK_DEPLOYER" "$PHOENIX_COLLECTOR_DEPLOYER" "$PHOENIX_OPEN_SELL_DEPLOYER")
  verify_one "$PHOENIX_LAUNCHER" "script/launch/PhoenixLauncher.sol:PhoenixLauncher" \
    --constructor-args "$ARGS" || FAIL=1

  ARGS=$(cast abi-encode "constructor(address,address)" "$PHOENIX_LAUNCHER" "$ADMIN_ADDRESS")
  verify_one "$ORCH" "script/launch/PhoenixOrchestrator.sol:PhoenixOrchestrator" \
    --constructor-args "$ARGS" || FAIL=1
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "One or more verifications failed. Re-run after fixing constructor args / API key." >&2
  exit 1
fi
echo "All contracts submitted for verification."
echo "PXT:        https://arbiscan.io/address/${PXT_ADDRESS}#code"
echo "Hook:       https://arbiscan.io/address/${PHOENIX_HOOK}#code"
echo "Collector:  https://arbiscan.io/address/${FEE_COLLECTOR}#code"
echo "SwapTest:   https://arbiscan.io/address/${POOL_SWAP_TEST}#code"
echo "OpenSell:   https://arbiscan.io/address/${ANTI_BOT_OPEN_SELL}#code"
echo "Launcher:   https://arbiscan.io/address/${PHOENIX_LAUNCHER:-}#code"
echo "Orch:       https://arbiscan.io/address/${ORCH}#code"
