# Phoenix Token metadata & icon

On-chain ERC-20 name/symbol are set in `evm/src/core/Pxt.sol` (`Phoenix Token` / `PXT`).
Wallets and Uniswap use **`logoURI`** from a Uniswap-style token list.

| Path | Purpose |
|------|---------|
| `icon/pxt.png` | Full-size icon (4153×4153 source) |
| `icon/pxt-128.png` | 128×128 wallet-friendly icon (uploaded to IPFS) |
| `out/` | Generated metadata + tokenlist (gitignored) |
| `deployed.env` | Last IPFS URIs after Pinata upload (gitignored) |

## Prerequisites

1. **`make launch`** — `PXT_ADDRESS` must exist in `evm/.env.$(CLUSTER)`.
2. **`PINATA_JWT`** in `evm/.env.secrets` (copy from `pxt-protocol-v2/evm/.env.secrets` or Pinata dashboard).

## Commands (repo root)

```bash
# Build local metadata + sync icons to web/public/token/
make token-metadata CLUSTER=arbitrum

# Upload icon to IPFS
make deploy-token-icon

# Upload icon + metadata.json + pxt.tokenlist.json to IPFS
make deploy-token-metadata CLUSTER=arbitrum
```

After upload, import **`TOKEN_LIST_URI`** in Uniswap / MetaMask, or add the token manually with **`TOKEN_ICON_URI`** as `logoURI`.

See `docs/TOKEN_METADATA.md`.
