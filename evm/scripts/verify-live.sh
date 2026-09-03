#!/usr/bin/env bash
# Verify a live launch on the chain's Etherscan V2 explorer.
# Usage: verify-live.sh <evm/.env.CLUSTER>
# Requires FORK_CHAIN_ID and an Etherscan V2 API key (ETHERSCAN_API_KEY,
# ARBISCAN_API_KEY, or BASESCAN_API_KEY).
#
# Launcher path: Pxt / hook / FeeCollector constructors take the orchestrator as admin,
# not the EOA. Mine hook with operator = OPEN_SELL_OPERATOR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:?usage: verify-live.sh <evm/.env.CLUSTER>}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run make launch CLUSTER=... first" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

API_KEY="${ETHERSCAN_API_KEY:-${ARBISCAN_API_KEY:-${BASESCAN_API_KEY:-}}}"
if [[ -z "$API_KEY" ]]; then
  echo "Set ETHERSCAN_API_KEY (or ARBISCAN_API_KEY / BASESCAN_API_KEY) in $ENV_FILE" >&2
  echo "Get a V2 key at https://etherscan.io/apidashboard" >&2
  exit 1
fi

: "${FORK_CHAIN_ID:?set FORK_CHAIN_ID in $ENV_FILE}"
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
CHAIN="$FORK_CHAIN_ID"

case "$CHAIN" in
  42161) EXPLORER="https://arbiscan.io" ;;
  8453) EXPLORER="https://basescan.org" ;;
  84532) EXPLORER="https://sepolia.basescan.org" ;;
  *) EXPLORER="https://etherscan.io" ;;
esac

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
    echo "FAILED: $contract (may already be verified — check $EXPLORER)" >&2
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
echo "PXT:        ${EXPLORER}/address/${PXT_ADDRESS}#code"
echo "Hook:       ${EXPLORER}/address/${PHOENIX_HOOK}#code"
echo "Collector:  ${EXPLORER}/address/${FEE_COLLECTOR}#code"
echo "SwapTest:   ${EXPLORER}/address/${POOL_SWAP_TEST}#code"
echo "OpenSell:   ${EXPLORER}/address/${ANTI_BOT_OPEN_SELL}#code"
echo "Launcher:   ${EXPLORER}/address/${PHOENIX_LAUNCHER:-}#code"
echo "Orch:       ${EXPLORER}/address/${ORCH}#code"
