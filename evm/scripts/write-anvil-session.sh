#!/usr/bin/env bash
# Record sell-unlock timestamp for the current Anvil fork session.
set -euo pipefail

EVM_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OUT="${EVM_DIR}/.anvil-session.env"

# Anvil uses live fork time (~now). Sell unlock must be in the future.
# SELL_UNLOCK_MINUTES (if set) wins over a leftover SELL_UNLOCK_TIMESTAMP from
# evm/.env.anvil (Makefile include/export). A past timestamp is ignored.
NOW=$(date +%s)
DEFAULT_UNLOCK=$(date -u -d '2027-03-01 00:00:00' +%s 2>/dev/null \
  || date -u -j -f '%Y-%m-%d %H:%M:%S' '2027-03-01 00:00:00' +%s)

if [[ -n "${SELL_UNLOCK_MINUTES:-}" ]]; then
  SELL_UNLOCK=$(( NOW + SELL_UNLOCK_MINUTES * 60 ))
elif [[ -n "${SELL_UNLOCK_TIMESTAMP:-}" && "${SELL_UNLOCK_TIMESTAMP}" -gt "$NOW" ]]; then
  SELL_UNLOCK="$SELL_UNLOCK_TIMESTAMP"
else
  if [[ -n "${SELL_UNLOCK_TIMESTAMP:-}" && "${SELL_UNLOCK_TIMESTAMP}" -le "$NOW" ]]; then
    echo "Ignoring past SELL_UNLOCK_TIMESTAMP=${SELL_UNLOCK_TIMESTAMP} (now=$NOW); using 2027-03-01 UTC" >&2
    echo "Override: SELL_UNLOCK_MINUTES=10 make anvil-base-sepolia-fork" >&2
  fi
  SELL_UNLOCK="$DEFAULT_UNLOCK"
fi

if [[ "$SELL_UNLOCK" -le "$NOW" ]]; then
  echo "SELL_UNLOCK_TIMESTAMP ($SELL_UNLOCK) must be after now ($NOW)." >&2
  echo "Use a future date or: SELL_UNLOCK_MINUTES=10 make anvil-base-sepolia-fork" >&2
  exit 1
fi

cat >"$OUT" <<EOF
# Written by make anvil-base-sepolia-fork - sell unlock for this Anvil session
SELL_UNLOCK_TIMESTAMP=${SELL_UNLOCK}
EOF

echo "Sell unlock timestamp: ${SELL_UNLOCK} ($(date -u -d "@${SELL_UNLOCK}" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -r "${SELL_UNLOCK}" '+%Y-%m-%d %H:%M:%S UTC'))"
echo "Wrote ${OUT}"
