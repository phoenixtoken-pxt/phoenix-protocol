#!/usr/bin/env bash
# Build PXT token metadata + Uniswap tokenlist from evm/.env.$(CLUSTER)
# and sync icons into web/public/token/ for local UI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
META_DIR="$ROOT/packages/token-metadata"
OUT_DIR="$META_DIR/out"
CLUSTER="${CLUSTER:-arbitrum}"
ENV_FILE="$ROOT/evm/.env.${CLUSTER}"

EXTERNAL_URL="${EXTERNAL_URL:-https://phoenixproject.community/}"
IMAGE_URI="${IMAGE_URI:-}"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a && . "$ENV_FILE" && set +a

PXT="${PXT_ADDRESS:-}"
if [[ -z "$PXT" || ! "$PXT" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
  echo "PXT_ADDRESS missing/invalid in $ENV_FILE — run make launch CLUSTER=$CLUSTER first" >&2
  exit 1
fi

case "$CLUSTER" in
  anvil) CHAIN_ID="${FORK_CHAIN_ID:-84532}" ;;
  arbitrum) CHAIN_ID="${FORK_CHAIN_ID:-42161}" ;;
  base) CHAIN_ID="${FORK_CHAIN_ID:-8453}" ;;
  *) CHAIN_ID="${FORK_CHAIN_ID:-}" ;;
esac
[[ -n "$CHAIN_ID" ]] || { echo "FORK_CHAIN_ID missing in $ENV_FILE" >&2; exit 1; }

ICON_SRC="$META_DIR/icon/pxt.png"
ICON_128="$META_DIR/icon/pxt-128.png"
[[ -f "$ICON_SRC" ]] || { echo "Missing $ICON_SRC" >&2; exit 1; }
[[ -f "$ICON_128" ]] || ICON_128="$ICON_SRC"

mkdir -p "$OUT_DIR" "$ROOT/web/public/token"
cp -f "$ICON_SRC" "$ROOT/web/public/token/pxt.png"
cp -f "$ICON_128" "$ROOT/web/public/token/pxt-128.png"

if [[ -z "$IMAGE_URI" ]]; then
  IMAGE_URI="/token/pxt-128.png"
  if [[ -f "$META_DIR/deployed.env" ]]; then
    # shellcheck disable=SC1090
    set -a && . "$META_DIR/deployed.env" && set +a
    if [[ -n "${TOKEN_ICON_URI:-}" ]]; then
      IMAGE_URI="$TOKEN_ICON_URI"
    fi
  fi
fi

export IMAGE_URI EXTERNAL_URL

node <<EOF
const fs = require("fs");
const path = require("path");

const pxt = "$PXT";
const chainId = Number("$CHAIN_ID");
const imageUri = process.env.IMAGE_URI;
const externalUrl = process.env.EXTERNAL_URL;
const now = new Date().toISOString();

const template = JSON.parse(
  fs.readFileSync(path.join("$META_DIR", "metadata.template.json"), "utf8")
);
const metadata = {
  ...template,
  image: imageUri,
  external_url: externalUrl,
  address: pxt,
  chainId,
};
fs.writeFileSync(
  path.join("$OUT_DIR", "metadata.json"),
  JSON.stringify(metadata, null, 2) + "\\n"
);

const tokenlist = {
  name: "Phoenix Token",
  timestamp: now,
  version: { major: 1, minor: 0, patch: 0 },
  tags: {},
  logoURI: imageUri,
  keywords: ["phoenix", "pxt", "phoenixtoken"],
  tokens: [
    {
      chainId,
      address: pxt,
      name: "Phoenix Token",
      symbol: "PXT",
      decimals: 6,
      logoURI: imageUri,
    },
  ],
};
fs.writeFileSync(
  path.join("$OUT_DIR", "pxt.tokenlist.json"),
  JSON.stringify(tokenlist, null, 2) + "\\n"
);

const summary = {
  cluster: "$CLUSTER",
  chainId,
  address: pxt,
  imageUri,
  metadata: path.join("$OUT_DIR", "metadata.json"),
  tokenlist: path.join("$OUT_DIR", "pxt.tokenlist.json"),
};
fs.writeFileSync(
  path.join("$OUT_DIR", "summary.json"),
  JSON.stringify(summary, null, 2) + "\\n"
);
console.log(JSON.stringify(summary, null, 2));
EOF

echo "Synced icons → web/public/token"
echo "Wrote $OUT_DIR/{metadata.json,pxt.tokenlist.json,summary.json}"
