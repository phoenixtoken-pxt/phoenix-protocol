# Audit remediations v2

Team notes against [audit-v2.pdf](audit-v2.pdf). **Every issue below is Status: Acknowledged.** No code change. 
---

## PTTB — PoolManager Transfer Tax Bypass

> **Status: Acknowledged**

Inbound tax bypass already fixed. Outbound: `from == poolManager` is fee-free and skips the contract-recipient allowlist (swaps, LP exits, ERC-6909 redeem). v4 settlement cannot be authenticated at the token. The allowlist is a P2P gate, not a hard custody rule.

## VEEO — Value Extraction Enabling Operations

> **Status: Acknowledged**

Same residual as **JLVE**. Buyback is keeper-only and limited vs previous-block official spot (2%). Remaining MEV is public-mempool sandwich inside that band. Ops: private relay, quote-based `minPxtBought`, clip vs depth.

## APTE — Alternate Pool Tax Evasion

> **Status: Acknowledged**

Hook fees apply only to the official pool. A no-hook v4 pool on the same PoolManager settles as a 2.7% transfer. Permissionless v4 cannot bind every pool at the token. Mitigation is liquidity + routing on the official pool.

## BIBP — Balance Inflation Bypasses Penalty

> **Status: Acknowledged**

Residual of **FBBP**. Same-tx PoolManager padding is excluded. Other inbound (EOA / lender) still counts; that path pays 2.7% both ways. Dump quota is pre-sell balance per address, not economic ownership.

## CCIB — Code-Length Check Is Bypassable

> **Status: Acknowledged**

23-byte path already closed (`_isWallet` is `code.length == 0` only). CREATE2 / constructor residual stands: zero code cannot prove a permanent EOA. Impact is routing tokens to a self-chosen contract, not a protocol drain.

## CCR — Contract Centralization Risk

> **Status: Acknowledged**

Owner setters are bootstrap. `LockProtocolReturnDelta` renounces Ownable on FeeCollector → Hook → Pxt before go-live. Post-lock: Safe may only manage contract recipients and buyback callers. `setLiquidityProvider` is gone.

## FWEPE — Fixed Windows Enable Penalty Evasion

> **Status: Acknowledged**

Dump window is a fixed 24h bucket from the first sell, not a rolling lookback. Around expiry a seller can clip ~19% of the then-current bag at base fee. Intended UX.

## FAPR — Fresh Address Penalty Reset

> **Status: Acknowledged**

Quota is per seller address. Sell 10% → transfer rest → repeat can leak more than 10% over time; each hop pays 2.7%, and selling 100% of a fresh wallet is still penalty. No transfer-window inheritance.

## MC — Missing Check

> **Status: Acknowledged**

One-shot owner config does not fully cross-check pool keys or cap recycle-width overflow. Wrong values brick **that** deploy. Bootstrap + lock are the check; no owner after renounce to fix or exploit.

## OPIIU — Official Pool Initialization Is Unrestricted

> **Status: Acknowledged**

No `beforeInitialize`. Anyone can init a known PoolKey first (grief / wrong spot). Production: initialize in the same tx/bundle as hook reveal; check spot before seed. After init, N/A.

## OSLP — Orphaned Sell Locks PXT

> **Status: Acknowledged**

Residual of **RIFM**. Exact-in burn leftover is refunded only in `attributeSell` (ERC-20). ERC-6909 partial fills never hit that; orphan finalize books USDC only. Unrefunded PXT can sit on the hook (1.85% of unfilled). No authentic 6909 beneficiary.

## STCBT — Seed Transfers Can Be Taxed

> **Status: Acknowledged**

Owner → collector PXT pays 2.7% unless the collector is `FeeExempt`. Bootstrap always sets that before `addLiquidity`. Collector is one-shot; there is no rotation.

## VPBB — Valid Price Breaks Buybacks

> **Status: Acknowledged**

`pxtForQuote` squares `uint160` in `uint256`, so sqrt prices `≥ 2^128` revert and can freeze buybacks. That band is pathological for PXT/USDC (6/6). Does not mis-pay a fill.
