# Phoenix Token (PXT)

Utility token for the Phoenix Token ecosystem. This repository implements **PXT** and a Uniswap v4 **ReturnDelta** hook on Base (EVM).

## Token

| | |
|--|--|
| **Name** | Phoenix Token |
| **Symbol** | PXT |
| **Type** | Utility token |
| **Decimals** | 6 |
| **Total supply** | 971,000,000,000 |
| **Fee wallets** | Immutable (`DONATION_WALLET`, `MARKETING_WALLET`). Cash buyback runs on `PhoenixFeeCollector`. |

## Fee rates

Wallet-to-wallet transfers take a **2.7%** fee unless the **recipient** is `FeeExempt` or `NoPenalty`. The sender’s status does not skip the transfer tax.

DEX buys and sells are enforced by the hook. Selling more than **10%** of a wallet’s balance within **24 hours** triggers the penalty tier (dump window). Fees are skimmed in USDC (plus a fixed **1.85% PXT burn** on sells); the dump window uses a pessimistic USDC skim with same-tx rebate via `Pxt` → `attributeSell`.

| Kind | Total | Split |
|------|------:|-------|
| **Buy** | 2.7% | 1.45% donations · 1.25% marketing |
| **Transfer** | 2.7% | 1.45% donations · 1.25% marketing |
| **Sell** (≤10% of wallet / 24h) | 5.4% | 1.25% donations · 1.15% marketing · 1.85% burn · 1.15% buyback |
| **Penalty** (>10% of wallet / 24h) | 37.8% | 1.25% donations · 1.15% marketing · 1.85% burn · 33.55% buyback |

## Token protection

- **Sell lock** — DEX sells locked until **1 March 2027** (immutable at deploy). Wallet transfers and buys still work.
- **Anti-bot** — After unlock, public sells open via atomic ops helper
  `PhoenixAntiBotOpenSell.openWithExactInSell` (clearSellProtection + ceremonial sell in one tx).
  The helper is set as on-chain `antiBotSeller`; only its immutable `operator` (usually Admin) may
  call it — no `tx.origin`. The hook enforces unlock **and** cleared anti-bot for ERC-20 and ERC-6909.
- **Dump window** — keyed by the authentic ERC-20 `seller → PoolManager` transfer on DEX settlement.
- **Official pool** — The hook binds a single `PoolId` before initialize.
- **Ownership / LP** — After seed LP, run the lock ceremony to renounce Ownable on FeeCollector, hook, and Pxt. PXT transfers to **EOAs / plain wallets stay unrestricted**; transfers **to smart contracts** (staking, bridges, etc.) require an allowlisted recipient. After renounce, only a multisig holding `RECIPIENT_APPROVER_ROLE` can call `setApprovedContractRecipient` to add or remove those contract addresses — not a general transfer gate on users.
- **LP gate** — Allowlisted providers only during sell lock; permissionless after sell unlock.
- **FeeExempt on DEX** — Full USDC skim rebate on sells (burn still applies). Retail buys still pay 2.7%.
- **NoPenalty** — Inbound transfers skip the 2.7% tax; DEX sells always pay base 5.4% USDC (never dump penalty).
- **Protocol buyback** — `executeBuyback` is **not permissionless**: only `isAuthorizedBuybackCaller` addresses may run it (keeper / ops). After lock, the deploy admin is cleared; a Safe with `BUYBACK_EXECUTOR_APPROVER_ROLE` can add or remove callers. Swaps from `FeeCollector` skip the hook buy skim (no double tax on recycle). Slippage is capped vs the **previous-block** official-pool spot (default **2%**, frozen at renounce), so same-block JIT cannot retarget the fill. Recycle LP ticks still use live spot. After large flow, keepers may wait one block so the freeze catches up. Prefer a private relay and a quote-based `minPxtBought`.

### Operational phases

**Phase one** — from **31 August 2026**: liquidity is added and locked; **buys are open**. **Sells stay locked** until **1 March 2027**.

**Phase two** (from **1 March 2027**) — sell unlock; public DEX trading.

## Layout

| Path | Purpose |
|------|---------|
| `evm/` | Foundry — PXT + Phoenix hook |
| `evm/src/core/` | Token + fee model (`Pxt`, `PxtFeeModel`, `PxtSellAccess`) |
| `evm/script/` | Bootstrap / lock / ops helpers (`PhoenixAntiBotOpenSell`, Anvil scripts) |
| `evm/src/fee/` | `PhoenixFeeCollector` (accrual) + `PhoenixBuyback` (LP/buyback) + `PhoenixBuybackMath` |
| `evm/src/return-delta/` | Return-delta USDC-skim hook |
| `evm/src/uniswap/v4/` | Addresses + hook CREATE2 miner |
| `web/` | Local Anvil UI |

## Prerequisites

```bash
make evm-deps
make evm-test          # Foundry unit/integration tests
```

Optional local UI: `make web-dev` (after a bootstrap that writes `web/.env`).

### Sell unlock on Anvil

`make anvil-base-sepolia-fork` writes `evm/.anvil-session.env` with the unlock used by bootstrap. Default is production (**1 March 2027**). Override when starting the fork:

```bash
SELL_UNLOCK_TIMESTAMP=1735689600 make anvil-base-sepolia-fork
# or
SELL_UNLOCK_MINUTES=10 make anvil-base-sepolia-fork
```

Warp past unlock without waiting:

```bash
make warp-anvil-unlock
```

---

## Local Anvil workflow

Hook: `PhoenixV4ReturnDeltaHook`. Pool fee is `0` (return-delta). Hook is set as `sellAttributor` on `Pxt`. Accrued USDC fees go to `PhoenixFeeCollector` for permissionless `collect` and authorized `executeBuyback`.

If settlement skips ERC-20 (e.g. ERC-6909 burn), call `finalizeOrphanedSell()` (or the next swap auto-finalizes) so fees reach the FeeCollector.

### 1. Start fork

```bash
# Terminal 1
make anvil-base-sepolia-fork
```

### 2. Deploy + seed LP

```bash
# Terminal 2
make bootstrap-anvil
# alias: make bootstrap-return-delta-anvil
```

Writes `evm/.env.anvil` and `web/.env` (addresses, pool, FeeCollector).

### 3. Optional lock ceremony

```bash
make lock-anvil
# RECIPIENT_APPROVER=0x...  # multisig; must differ from deployer
# BUYBACK_CALLERS=0x...     # keeper EOAs (required; deployer is cleared)
```

### 4. Exercise swaps (after unlock)

```bash
make warp-anvil-unlock
make open-trading-anvil AMOUNT_WHOLE=100
# Or web UI: Open trading (clear + sell)

make fund-testers-anvil
make swap-anvil DIRECTION=buy AMOUNT_WHOLE=100
make swap-anvil DIRECTION=sell AMOUNT_WHOLE=50
```

### 5. Collect + buyback

USDC fees are already accrued to the FeeCollector on attribution / orphan finalize. Then:

```bash
make collect-fees-anvil
make execute-buyback-anvil
make status-anvil

# Or one-shot dry-run (unlock → sells → collect → buyback):
make demo-buyback-anvil
```

### 6. Unit tests

```bash
cd evm && forge test --match-contract PhoenixV4ReturnDeltaHookTest -vv
```

---

## Shared Anvil helpers

| Target | Purpose |
|--------|---------|
| `make fund-testers-anvil` | Mint mUSDC + distribute PXT to tester accounts |
| `make distribute-pxt-anvil` | Distribute PXT only |
| `make web-dev` | Local UI against the last bootstrap |
| `make explorer` | Otterscan against Anvil (Docker) |

Addresses and keys for local demos live in `evm/.env.anvil.example` (copied/filled by bootstrap into `evm/.env.anvil`).
