# Audit remediations - Phoenix Protocol

Team notes against [audit.pdf](audit.pdf) (Cyberscope, Aug 2026, commit `752cf67`). Scope for the review is [AUDIT_SCOPE.md](../../AUDIT_SCOPE.md) (`evm/src/` only).

---

## ST — Stops Transactions

| | |
|--|--|
| **Criticality** | Critical |
| **PDF** | `Pxt.sol`, `PxtSellAccess.sol`, `PhoenixV4ReturnDeltaHook.sol` |
| **Our status** | Resolved (anti-bot freeze + one-shot wiring). Runtime collector/attributor revert is accepted, not try/caught. |
| **Code** | `62f00b9` (`fix: remediate ST - Stops Transactions`) |

### Finding (two halves)

1. **Owner sell-freeze.** While Ownable is live, `setAntiBotSeller` could be called after unlock and set `sellProtectionCleared = false`. Only the new anti-bot address could sell; hook sells hit `enforceTradingOpen`. Buys and wallet transfers still worked. Renounce removed the vector only if the lock ceremony actually ran.

2. **Hard dependencies.** Every ERC-20 sell calls `sellAttributor.attributeSell`; fee finalization calls `feeCollector.receiveAccruedFees`. A wrong or reverting address bricks sells. An unfinalizable orphan makes `_beforeSwap` call `finalizeOrphanedSell` and can brick **all** official-pool swaps. Setters accepted any nonzero address.

### What we shipped

**Anti-bot is one-way** (`Pxt.setAntiBotSeller`):

- Reverts `AntiBotSellerAlreadySet` if a seller is already configured.
- Reverts `SellProtectionAlreadyCleared` if public sells have already opened.
- **Does not** assign `sellProtectionCleared = false`. Once true, no admin path can undo it.

Public sells still open via `clearSellProtection` (designated seller after unlock) or auto-clear on that seller’s first DEX sell. Tests: `test_setAntiBotSeller_one_shot`, `test_setAntiBotSeller_cannot_rearm_after_clear`.

**Collector and attributor are one-shot** (`setFeeCollector`, `setSellAttributor`): cannot be rotated after bootstrap. A mis-set address is still fatal, but it cannot be swapped in later to freeze sells. PoolManager / FeeCollector / sell attributor remain **protected recipients** (already in `752cf67`): the allowlist bit cannot be revoked, so DEX settlement cannot be gated off that way.

Lock-script checks (out of auditor `src` scope, still required for go-live) verify hook = attributor, matching fee wallets, and Pxt’s collector address before Ownable renounce.

### Rejected / not done

We did **not** wrap `attributeSell` / `receiveAccruedFees` in try/catch. Swallowing `attributeSell` would leave hook transient skim open (`PendingSellOpen`) and make the next swap worse. Official-pool sells **should** revert if the wired hook or collector is broken; that is the same as a broken DEX, not a selective freeze the owner can toggle.

We did **not** skip auto-finalize of orphans on collector failure. Retry remains permissionless `finalizeOrphanedSell`.

### Residual risk

- Until Ownable is renounced, the owner can still `setWalletStatus` and other admin functions (see CCR). ST’s **sell-freeze-after-open** path is closed in code even before renounce.
- A one-shot wrong attributor/collector at bootstrap still bricks sells until a new deploy. That is deploy-time, not a post-open toggle.
- If the collector later reverts on `receiveAccruedFees`, an orphan can still stall official-pool swaps until it is fixed or finalized. We accepted that over hiding fee failures.

---

## PBRD — Persistent Band Registry DoS

| | |
|--|--|
| **Criticality** | Critical |
| **PDF** | `PhoenixBuyback.sol` (`recycleBands`, `_selectPxtOnlyRecycleBand`) |
| **Our status** | Resolved |
| **Code** | Working tree (with authorized buyback + collect cleanup) |

### Finding

Recycle LP is never withdrawn. `pruneEmptyRecycleBands` only dropped **zero-liquidity** rows. Permissionless `executeBuyback` could fill the 32-cap registry, move spot until no listed band was PXT-only, then `_selectPxtOnlyRecycleBand` reverted `RecycleBandNotPxtOnly` and **all future buybacks died**.

### Constraints (product)

- Do not burn or remove **in-range** recycle LP.
- Never have the protocol pull USDC from the pool to mint recycle.
- Keep bought PXT in Uniswap positions.

### Why the list existed

v2 charged **dynamic Uniswap LP fees**; `collect` harvested fee growth. This ReturnDelta stack added `recycleBands[]` so `collect` could walk recycle ranges. **Pool fee is 0.** Real fees are hook USDC skims via `receiveAccruedFees`. The 32-cap walk was leftover and caused PBRD. The Uniswap position `(this, ticks, RECYCLE_SALT)` is the source of truth; the array was only an index for a no-op collect path.

### What we shipped

Deleted the registry (`recycleBands`, `MAX_RECYCLE_BANDS`, prune, `_selectPxtOnlyRecycleBand`). Each buyback **always mints the current ideal PXT-only band** (`recycleTicks` from live `slot0`). `quoteDelta < 0` still reverts `RecycleBandNotPxtOnly` (never pull USDC). Kept `RECYCLE_SALT`, `recyclePxt`, `lastRecycleTick*`, `RecycleLiquidityAdded`.

`collect()` no longer pulls Uniswap LP fees (always empty at fee 0). It only pays pending donation / marketing / burn from on-hand tokens. Buyback pending stays for `executeBuyback`.

`executeBuyback` is **allowlisted** (`isAuthorizedBuybackCaller`). That was not required to delete the registry, but it removes the permissionless “fill the list” grief that the finding assumed.

### Residual risk

Many PoolManager recycle positions can exist over time (one per distinct tick floor). That is intended: we do not migrate or burn in-range LP. There is no on-contract cap that can DoS buybacks. Gas for a single mint is bounded; we do not walk a registry.

---

## JLVE — JIT Liquidity Value Extraction

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixBuyback.sol`, `PhoenixBuybackMath.sol` |
| **Our status** | Resolved on-chain for attacker-triggered + same-block spot retarget. Sandwich of a public-mempool keeper is ops. |
| **Code** | Working tree (`noteOfficialSpot` / `frozenSqrtPriceX96`) |

### Finding

Anyone could fire a predictable buyback. `expectedPxt` and `sqrtLimit` came from **this-block** `getSlot0`. An attacker could JIT or move spot, call `executeBuyback` with `minPxtBought = 0`, stay inside `maxBuybackSlippageBps` (default 2%), and unwind.

### What does not close it

Allowlisting keepers alone (sandwich still uses live spot). Forbidding `minPxtBought == 0`. Tightening the bps (still vs manipulated spot). A Uniswap v4 pool TWAP — v4 core has no `observe()`.

### What we shipped

1. **Allowlist.** Only `isAuthorizedBuybackCaller` may call `executeBuyback`. After lock, deployer is cleared; a Safe with `BUYBACK_EXECUTOR_APPROVER_ROLE` manages the list. Stops *attacker-triggered* buybacks (the “anyone may execute” half).

2. **Previous-block spot as fill reference.** Official-pool `afterSwap` (including protocol buybacks) calls `noteOfficialSpot` **before** the FeeCollector buy-skim skip. Collector keeps `pendingSqrtPriceX96` / `pendingSpotBlock` (this block) and `frozenSqrtPriceX96` (last **prior** block). `executeBuyback` **promotes first** if `block.number > pendingSpotBlock`, then sizes/limits vs **frozen**. Reverts `BuybackPriceNotWarmed` until at least one official swap has been promoted. Recycle ticks still use **live** `getSlot0`.

Same-block JIT updates pending, not frozen. Tests: `test_buyback_requires_prior_block_spot`, `test_buyback_uses_frozen_previous_block_spot`, `test_buyback_rejects_same_block_spot_manipulation`. Foundry stays on one block — unit tests `vm.roll` before a successful buyback.

### Residual risk

- Uniswap spot only moves on swaps. A calendar-old freeze **is** last trade if the book is quiet. After this-block flow, freeze is start-of-block (the anti-JIT rule). Keepers may wait one block after large volume so freeze catches up.
- A public-mempool keeper with `minPxtBought = 0` can still be sandwiched **within 2% of the frozen price**, not of live spot. Prefer a private relay and a quote-based `minPxtBought`.
- This is not a TWAP. It is last prior-block official-pool spot.
- `collect()` stays permissionless (payout only).
