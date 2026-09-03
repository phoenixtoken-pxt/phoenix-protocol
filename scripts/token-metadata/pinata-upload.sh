#!/usr/bin/env bash
# Upload a file to Pinata IPFS. Prints the gateway URI on stdout.
# Requires: PINATA_JWT (from env, evm/.env.secrets, or cluster env)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/token-metadata/load-env.sh"

FILE="${1:-}"
NAME="${2:-$(basename "$FILE")}"

[[ -n "$FILE" && -f "$FILE" ]] || { echo "Usage: $0 <file> [name]" >&2; exit 1; }
[[ -n "${PINATA_JWT:-}" ]] || {
  echo "PINATA_JWT is not set. Add it to evm/.env.secrets (see evm/.env.secrets.example)." >&2
  exit 1
}

GATEWAY="${PINATA_GATEWAY:-https://gateway.pinata.cloud/ipfs}"

RESP="$(curl -sS -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
  -H "Authorization: Bearer $PINATA_JWT" \
  -F "file=@${FILE};filename=${NAME}" \
  -F "pinataMetadata={\"name\":\"${NAME}\"}")"

CID="$(node -e 'const j=JSON.parse(process.argv[1]); if(!j.IpfsHash){console.error(j); process.exit(1)}; console.log(j.IpfsHash)' "$RESP")"
echo "${GATEWAY%/}/${CID}"
