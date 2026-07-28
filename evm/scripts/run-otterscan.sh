#!/usr/bin/env bash
# Start Otterscan against local Anvil (browser talks to ANVIL_RPC_URL directly).
set -euo pipefail

ANVIL_RPC_URL="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
EXPLORER_PORT="${EXPLORER_PORT:-5100}"
EXPLORER_NAME="${EXPLORER_NAME:-pxt-otterscan}"
EXPLORER_IMAGE="${EXPLORER_IMAGE:-otterscan/otterscan:latest}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

need docker
need curl

if ! curl -sf -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "$ANVIL_RPC_URL" >/dev/null; then
  echo "Anvil is not reachable at $ANVIL_RPC_URL" >&2
  echo "Start it first: make anvil-base-sepolia-fork" >&2
  exit 1
fi

# Otterscan SPA calls this URL from the browser - must be host-reachable, not docker-internal.
CONFIG=$(
  cat <<EOF
{
  "erigonURL": "${ANVIL_RPC_URL}",
  "experimental": false,
  "experimentalFixedChainId": 84532,
  "branding": {
    "siteName": "PXT Anvil",
    "networkTitle": "Base Sepolia fork (Anvil)"
  },
  "chainInfo": {
    "name": "Anvil Base Sepolia Fork",
    "faucets": [],
    "nativeCurrency": {
      "name": "Ether",
      "symbol": "ETH",
      "decimals": 18
    }
  }
}
EOF
)

if docker ps -a --format '{{.Names}}' | grep -qx "$EXPLORER_NAME"; then
  echo "Removing existing container $EXPLORER_NAME..."
  docker rm -f "$EXPLORER_NAME" >/dev/null
fi

echo "Starting Otterscan → Anvil $ANVIL_RPC_URL"
docker run -d --rm \
  --name "$EXPLORER_NAME" \
  -p "${EXPLORER_PORT}:80" \
  -e "OTTERSCAN_CONFIG=${CONFIG}" \
  "$EXPLORER_IMAGE" >/dev/null

echo
echo "Otterscan:  http://127.0.0.1:${EXPLORER_PORT}"
echo "RPC:        ${ANVIL_RPC_URL}"
echo "Stop with:  make explorer-stop"
echo
echo "Tip: after bootstrap, paste addresses from evm/.env.anvil (PXT_ADDRESS, HOOK_ADDRESS, ...)."
