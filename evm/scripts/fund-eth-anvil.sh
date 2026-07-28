#!/usr/bin/env bash
# Fund Anvil accounts with ETH via anvil_setBalance (local fork only).
#
# Usage:
#   fund-eth-anvil.sh [recipients]
#     recipients - optional comma-separated addresses; when omitted, uses env defaults
#
# Env:
#   ANVIL_RPC_URL              default http://127.0.0.1:8545
#   FUND_ETH_AMOUNT            default 10ether - target balance per address
#   FUND_ETH_MODE              min (default) | set
#                              min: top up only when balance < FUND_ETH_AMOUNT
#                              set: always set balance to FUND_ETH_AMOUNT
#   FUND_ETH_ALL               when true, fund mnemonic accounts #0..ANVIL_ACCOUNTS-1
#   ANVIL_ACCOUNTS             default 10
#   ANVIL_MNEMONIC             default Anvil junk mnemonic
#   FUND_ETH_INCLUDE_PROTOCOL  default true - add admin + fee wallets from evm/.env.anvil
#   FUND_ETH_INCLUDE_TESTERS   default true - add TESTER_RECIPIENTS / RECIPIENTS
#   ADMIN_ADDRESS, DONATION_WALLET, MARKETING_WALLET, NO_PENALTY_WALLET, SHARES_WALLET
#   TESTER_RECIPIENTS, RECIPIENTS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RPC_URL="${ANVIL_RPC_URL:-http://127.0.0.1:8545}"
AMOUNT="${FUND_ETH_AMOUNT:-${TESTER_ETH_AMOUNT:-10ether}}"
MODE="${FUND_ETH_MODE:-min}"
ACCOUNTS="${ANVIL_ACCOUNTS:-10}"
MNEMONIC="${ANVIL_MNEMONIC:-test test test test test test test test test test test junk}"
INCLUDE_PROTOCOL="${FUND_ETH_INCLUDE_PROTOCOL:-true}"
INCLUDE_TESTERS="${FUND_ETH_INCLUDE_TESTERS:-true}"
FUND_ALL="${FUND_ETH_ALL:-false}"

# Load evm/.env.anvil when present (bootstrap output).
if [[ -f "$ROOT/.env.anvil" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env.anvil"
  set +a
fi

DEFAULT_TESTERS="0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,0x976EA74026E726554dB657fA54763abd0C3a0aa9,0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"

check_anvil() {
  cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 || {
    echo "Anvil not reachable at $RPC_URL - start: make anvil-base-sepolia-fork" >&2
    exit 1
  }
}

# cast to-wei rejects "10ether" on some versions - strip the suffix.
to_wei() {
  local amount="${1//ether/}"
  cast to-wei "$amount"
}

to_hex_wei() {
  python3 -c "print(hex(int('${1}')))"
}

add_addr() {
  local addr="${1,,}"
  [[ -z "$addr" || "$addr" == "0x0000000000000000000000000000000000000000" ]] && return
  if [[ -z "${SEEN[$addr]:-}" ]]; then
    SEEN[$addr]=1
    RECIP_LIST+=("$addr")
  fi
}

add_csv() {
  local csv="$1"
  [[ -z "$csv" ]] && return
  IFS=',' read -ra ADDRS <<<"$csv"
  for addr in "${ADDRS[@]}"; do
    add_addr "$(echo "$addr" | xargs)"
  done
}

check_anvil

declare -A SEEN=()
RECIP_LIST=()

if [[ "${1:-}" != "" ]]; then
  add_csv "$1"
elif [[ "$FUND_ALL" == "true" ]]; then
  echo "Deriving Anvil accounts #0-$((ACCOUNTS - 1))..."
  for i in $(seq 0 $((ACCOUNTS - 1))); do
    add_addr "$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$i")"
  done
else
  if [[ "$INCLUDE_PROTOCOL" == "true" ]]; then
    add_addr "${ADMIN_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
    add_addr "${DONATION_WALLET:-0x70997970C51812Dc3a010C7d01b50b0d17Ef88c8}"
    add_addr "${MARKETING_WALLET:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}"
    add_addr "${NO_PENALTY_WALLET:-0x90F79bf6EB2c4f870365E785982E1f101E93b906}"
    add_addr "${SHARES_WALLET:-0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65}"
  fi
  if [[ "$INCLUDE_TESTERS" == "true" ]]; then
    add_csv "${RECIPIENTS:-${TESTER_RECIPIENTS:-$DEFAULT_TESTERS}}"
  fi
fi

if [[ ${#RECIP_LIST[@]} -eq 0 ]]; then
  echo "No recipients - pass addresses or set FUND_ETH_ALL=true" >&2
  exit 1
fi

TARGET_WEI="$(to_wei "$AMOUNT")"
TARGET_HEX="$(to_hex_wei "$TARGET_WEI")"
RECIPIENTS_CSV="$(IFS=,; echo "${RECIP_LIST[*]}")"

bash "$SCRIPT_DIR/reset-tester-eoas.sh" "$RECIPIENTS_CSV" "$RPC_URL"

echo "Funding ${#RECIP_LIST[@]} address(es) to $AMOUNT (mode=$MODE)..."
for addr in "${RECIP_LIST[@]}"; do
  current="$(cast balance "$addr" --rpc-url "$RPC_URL")"
  if [[ "$MODE" == "set" ]] || python3 -c "import sys; sys.exit(0 if int('$current') < int('$TARGET_WEI') else 1)"; then
    cast rpc anvil_setBalance "$addr" "$TARGET_HEX" --rpc-url "$RPC_URL" >/dev/null
    echo "  $addr → $AMOUNT"
  else
    echo "  $addr - already $(cast from-wei "$current") ETH (skip)"
  fi
done

echo "Done."
