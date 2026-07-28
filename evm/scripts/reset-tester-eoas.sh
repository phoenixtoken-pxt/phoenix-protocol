#!/usr/bin/env bash
# Clear forked EIP-7702 delegation bytecode on tester addresses so MetaMask treats
# them as plain EOAs (otherwise eth_sendTransaction can fail with empty calldata).
# Usage: reset-tester-eoas.sh <recipients> [rpc_url]
set -euo pipefail

RECIPIENTS="${1:?recipients required (comma-separated)}"
RPC_URL="${2:-http://127.0.0.1:8545}"

IFS=',' read -ra ADDRS <<<"$RECIPIENTS"
for addr in "${ADDRS[@]}"; do
  addr="$(echo "$addr" | xargs)"
  [[ -z "$addr" ]] && continue
  code="$(cast code "$addr" --rpc-url "$RPC_URL")"
  if [[ "$code" != "0x" ]]; then
    echo "Clearing fork overlay code on $addr (was ${#code} bytes)"
    cast rpc anvil_setCode "$addr" 0x --rpc-url "$RPC_URL" >/dev/null
  fi
done
