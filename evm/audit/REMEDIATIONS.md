# Audit remediations - Phoenix Protocol

Team notes against [audit.pdf](audit.pdf) (Cyberscope, Aug 2026, commit `752cf67`). Scope for the review is [AUDIT_SCOPE.md](../../AUDIT_SCOPE.md) (`evm/src/` only). **Criticality** labels match the PDF (Critical / Medium / Minor / Informative).

---

## ST — Stops Transactions

| | |
|--|--|
| **Criticality** | Critical |
| **PDF** | `Pxt.sol`, `PxtSellAccess.sol`, `PhoenixV4ReturnDeltaHook.sol` |
| **Our status** | Resolved. Ownable is renounced on Pxt, Hook, and FeeCollector **before go-live** (`LockProtocolReturnDelta`); no owner remains who can re-freeze sells or rotate wiring after launch. Anti-bot freeze + one-shot wiring in code. Runtime collector/attributor revert is accepted, not try/caught. |
| **Code** | `62f00b9` (`fix: remediate ST - Stops Transactions`) |

### Finding (two halves)

1. **Owner sell-freeze.** While Ownable is live, `setAntiBotSeller` could be called after unlock and set `sellProtectionCleared = false`. Only the new anti-bot address could sell; hook sells hit `enforceTradingOpen`. Buys and wallet transfers still worked. **Not a production issue:** we renounce Ownable on Pxt (and Hook / FeeCollector) before go-live; after lock there is no owner who can re-arm the freeze.

2. **Hard dependencies.** Every ERC-20 sell calls `sellAttributor.attributeSell`; fee finalization calls `feeCollector.receiveAccruedFees`. A wrong or reverting address bricks sells. An unfinalizable orphan makes `_beforeSwap` call `finalizeOrphanedSell` and can brick **all** official-pool swaps. Setters accepted any nonzero address. Mitigated by one-shot setters + lock-script checks before renounce; post-launch there is no owner to point at a malicious address.

### What we shipped

**Anti-bot is one-way** (`Pxt.setAntiBotSeller`):

- Reverts `AntiBotSellerAlreadySet` if a seller is already configured.
- Reverts `SellProtectionAlreadyCleared` if public sells have already opened.
- **Does not** assign `sellProtectionCleared = false`. Once true, no admin path can undo it.

Public sells still open via `clearSellProtection` (designated seller after unlock) or auto-clear on that seller’s first DEX sell. Tests: `test_setAntiBotSeller_one_shot`, `test_setAntiBotSeller_cannot_rearm_after_clear`.

**Collector and attributor are one-shot** (`setFeeCollector`, `setSellAttributor`): cannot be rotated after bootstrap. A mis-set address is still fatal, but it cannot be swapped in later to freeze sells. PoolManager / FeeCollector / sell attributor remain **protected recipients** (already in `752cf67`): the allowlist bit cannot be revoked, so DEX settlement cannot be gated off that way.

Lock-script checks (out of auditor `src` scope, **required before go-live**) verify hook = attributor, matching fee wallets, and Pxt’s collector address, then **renounce Ownable** on FeeCollector → Hook → Pxt. Trading is not considered live until that ceremony completes; with `owner == address(0)`, the audit’s owner-toggle sell-freeze and mis-set wiring paths no longer apply.

### Rejected / not done

We did **not** wrap `attributeSell` / `receiveAccruedFees` in try/catch. Swallowing `attributeSell` would leave hook transient skim open (`PendingSellOpen`) and make the next swap worse. Official-pool sells **should** revert if the wired hook or collector is broken; that is the same as a broken DEX, not a selective freeze the owner can toggle.

We did **not** skip auto-finalize of orphans on collector failure. Retry remains permissionless `finalizeOrphanedSell`.

### Residual risk

- **Pre-go-live only:** Until the lock ceremony runs, the deployer still has Ownable admin powers (e.g. `setWalletStatus`; see CCR). ST’s **sell-freeze-after-open** path is already closed in code even before renounce. **Production assumption:** renounce before any public trading; ST is not treated as open after lock.
- A one-shot wrong attributor/collector at bootstrap still bricks sells until a new deploy. That is deploy-time verification, not a post-launch owner toggle.
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

---

## LRSA — Liquidity Refund Sweeps Accruals

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixBuyback.addLiquidity` refunds `balanceOf(this)` |
| **Our status** | Resolved |
| **Code** | Working tree (`seedLiquidityAdded`) |

### Finding

`addLiquidity` sent the collector’s entire leftover PXT/USDC to the owner after mint, including fee USDC already sitting on the contract. Pendings were unchanged, so the bag went short.

### What we shipped

`addLiquidity` is **one-shot** (`seedLiquidityAdded`). A second call reverts `LiquidityAlreadySeeded`. Recycle LP (`RECYCLE_SALT` inside `executeBuyback`) is unaffected. Extra owner LP later is minted on Uniswap, not through this function.

Intended order: seed once at bootstrap (no fees yet), then lock. The first-call leftover refund is unused seed, not fee USDC.

---

## CMBS — Collector Misaccounts Buyback Solvency

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixFeeCollector._payoutToken` / `_reconcileWalletBurnPending`; `addLiquidity` refund |
| **Our status** | Resolved |
| **Code** | Working tree (one-shot seed + collect reserves `pendingBuyback`) |

### Finding

Donation / marketing / burn / buyback share one ERC-20 balance. `collect` and reconcile only looked at the first three. If cash was already below the labels (the LRSA refund), wallets got paid from what was left and `pendingBuyback` stayed as a phantom.

### What we shipped

One-shot seed removes the owner sweep. `collect` pays wallets/burn only from `balance − pendingBuyback`. Reconcile haircuts **all four** legs when short (buyback kept first, then burn, then wallets). `executeBuyback` / `quoteBuyback` reserve wallet+burn dues the same way, then clip leftover buyback pending to remaining cash.

### Residual risk

On a short collector, unpaid donation/marketing is written off so buyback cash is not donated. Surplus tokens above all pendings are unused (not auto-assigned).

---

## FBBP — Flash-Borrowed Balance Bypasses Penalty

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixV4ReturnDeltaHook` dump window (`balanceAtWindowStart`) |
| **Our status** | Resolved |
| **Code** | Working tree (`creditFromPoolManager` + snapshot ratchet) |

### Finding

The 10% dump denominator was `balanceOf + this sell` on the first sale, then frozen for 24h. Same-tx PXT taken from the PoolManager inflated that snapshot. Repaying it was a transfer to the PoolManager with no pending skim, so it did not add to `soldInWindow`. Later sells could dump the real bag at 5.4%.

### What we shipped

`Pxt._update` notifies the hook on PoolManager→user receipts (`creditFromPoolManager`, transient). `attributeSell` uses `balance − sameTxFromPm`. An open window’s `balanceAtWindowStart` ratchets down when `effectiveBefore` is smaller.

### Residual risk

Same-tx buy/LP-exit PXT is also excluded (stricter). If they repay the flash *before* the sell in the same tx, the denominator can collapse to this sell size (always penalty) — conservative.

---

## PTTB — PoolManager Transfer Tax Bypass

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `Pxt._quoteTransfer` / user→PoolManager |
| **Our status** | Resolved |
| **Code** | Working tree (`pendingDexSellAmount` / `consumeLpInbound`) |

### Finding

Every `user → PoolManager` transfer skipped the 2.7% wallet tax (treated as a DEX sell). `attributeSell` no-ops when there is no pending skim. After unlock, a locker could transfer PXT onto the PoolManager and `take` it to a friend tax-free.

### What we shipped

Fee-free inbound only when the hook attests it:

- DEX sell: `afterSwap` has already stored `pendingDexSellAmount` (including zero-USDC-skim sells).
- LP mint: `afterAddLiquidity` reserves the PXT owed; `consumeLpInbound` spends that budget.
- FeeCollector / owner seed before unlock stay fee-free.

Anything else `to == poolManager` pays the 2.7% transfer tax. `from == poolManager` (buys / LP exits) stays fee-free.

### Residual risk

Flash repay (`user → PoolManager` with no pending sell) pays 2.7% — conservative. Public LP after sell-unlock is not a sell, so it no longer requires anti-bot clear. A leftover LP inbound budget cannot cover a larger hop (amount-bounded). `setPoolManager` remains rotatable until Ownable is renounced.

---

## RIFM — Requested Input Fee Mispricing

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixV4ReturnDeltaHook` `beforeSwap` / `afterSwap` |
| **Our status** | Resolved |
| **Code** | Working tree (`grossUp`, exact-in true-up, exact-out fee-on-net) |

### Finding (two halves)

1. **Exact-in.** Fees and the 1.85% PXT burn were sized from `amountSpecified` in `beforeSwap`. A price-limit partial fill still paid as if the full request had traded.

2. **Exact-out.** Buy/sell USDC skims (and the unspecified PXT burn) were `net × bps / 10000` added on top of the pool leg. Published 2.7% / 5.4% / 37.8% therefore applied to *net*, not to total flow (auditor example: dump USDC ~26.44% of output instead of 35.95% of gross).

### What we shipped

`PxtFeeModel.grossUp(net, bps)` = `net * bps / (BPS - bps)`, so `fee / (net + fee)` matches the published bps (floor).

**Exact-in.** `beforeSwap` still takes a pessimistic specified slice (1.85% PXT / 2.7% USDC of the *request*) so the pool can fill. Uniswap v4 freezes specified hook delta after `beforeSwap`, so the user still *settles* that slice. `afterSwap` burns/accrues `grossUp(filled pool leg)`. Unfilled PXT burn is refunded to the authentic seller in `attributeSell` (fee-free hook outbound). Unfilled buy USDC is booked as extra buyback (no buyer identity on the hook). Full-fill sells match the old `request * bps / BPS` burn.

**Exact-out.** Specified notional stays the user's net. USDC skim (and buy unspecified take) is `grossUp` of that net at the published USDC/buy bps. Sell attribution stores `feeOnNet` so rebate/orphan splits gross-up the same net, not a pre-grossed figure (that would mis-rebate). Exact-in USDC sell skim stays `% of pool output` (`feeOnNet = false`).

Tests: `test_exact_in_sell_partial_fill_burns_actual`, `test_exact_out_buy_grosses_up_usdc_fee`, exact-out sell/penalty pending vs grossed notional, `PxtFeeModel` `grossUp` unit/fuzz.

### Residual risk

Floor division can leave 1 wei vs a naive `gross * bps / BPS`. Exact-in specified payment cannot be reduced in `afterSwap`; sell PXT leftover is refunded in `attributeSell`, exact-in buy leftover has no authentic buyer and is accrued as buyback. ERC-6909 exact-in partial fills never hit `attributeSell`, so leftover PXT can sit on the hook until a later flow. Hook outbound PXT is fee-free.

---

## RAAAU — Router Allowlist Authorizes All Users

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixV4ReturnDeltaHook` `_beforeAddLiquidity` / `liquidityProvider` |
| **Our status** | Resolved |
| **Code** | Working tree (FeeCollector-only pre-lock LP) |

### Finding

Pre-unlock LP used `liquidityProvider[sender]` where `sender` is PoolManager’s direct caller — usually a shared Position Manager / router, not the beneficial provider. Allowlisting that router lets **any** user mint through it. `hookData` is chosen by the locker and is not authentic identity.

### What we shipped

Removed `liquidityProvider` / `setLiquidityProvider`. While `block.timestamp < sellUnlock`, adds require `sender == address(feeCollector)`.

Protocol seed and recycle call `modifyLiquidity` from FeeCollector’s `unlockCallback`, so `sender` is the collector — not a shared router. Strangers (and admin) using `lpRouter` / POSM still have `sender = router` and revert `LiquidityNotAllowed`. After sell unlock the gate is off (permissionless LP).

Tests: `test_lp_gate_blocks_stranger_during_sell_lock`, `test_lp_gate_blocks_router_even_for_admin`, `test_lp_gate_allows_stranger_after_sell_unlock`.

### Residual risk

No extra team LP via public routers before unlock — only one-shot seed + recycle through FeeCollector. If pre-lock LP from another contract is ever needed, deploy a dedicated non-shared locker (not POSM), not a mapping allowlist on shared routers.

---

## APTE — Alternate Pool Tax Evasion

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `Pxt.sol`, `PhoenixV4ReturnDeltaHook.sol` |
| **Our status** | Accepted (by design) |
| **Code** | N/A |

### Finding

Hook fees, burn, and dump-window logic apply only to the one **official** pool (`officialPoolId`). Anyone can still open another PXT/USDC v4 pool on the same `PoolManager` with a different hook; swaps there skip Phoenix economics. On-token, those sells usually hit the 2.7% transfer tax only (no `pendingDexSellAmount` / full hook stack).

### Decision

Accepted. Permissionless v4 cannot bind all PXT pools at the token layer without breaking LP settle, buyback, and PTTB-style `PoolManager` flows. Official pool is the product surface: seeded LP, buyback/recycle, and frontends route there.

### Not done

No global pool ban, no “every `user → PoolManager` must be an official-hook sell”, no tax on all `PoolManager` outbound.

### Residual risk

Users can trade thin alternate pools at lower all-in cost. Mitigation is liquidity + routing on the official pool, not on-chain pool enumeration.

---

## UBFS — Unspent Buyback Funds Stranded

| | |
|--|--|
| **Criticality** | Medium |
| **PDF** | `PhoenixBuyback.sol` `_executeBuybackCash` / `unlockCallback` |
| **Our status** | Resolved |
| **Code** | Working tree |

### Finding

Cash buyback debited the full requested `spend` from `pendingBuyback` and reported `usdcSpent = spend`, but the v4 swap can stop at `sqrtPriceLimitX96` with a partial fill. Only `quoteOwed` from the swap delta is settled — the rest stayed on the collector while accounting treated it as spent.

### What we shipped

`unlockCallback` returns actual `quoteSpent`; `_executeBuybackCash` sets `usdcSpent` and reduces `pendingBuyback` by that amount. Min-out sizing uses the filled USDC, not the requested budget.

Test: `test_buyback_partial_fill_keeps_pending` (tight slippage → partial fill, pending matches actual spend).

---

## CCIB — Code-Length Check Is Bypassable

| | |
|--|--|
| **Criticality** | Minor / Informative |
| **PDF** | `Pxt.sol` `_isWallet` / `_enforceContractRecipient` |
| **Our status** | Resolved (23-byte bypass closed; CREATE2 pre-fund accepted) |
| **Code** | Working tree |

### Finding

Contract-recipient gating treated `code.length == 0` or 23-byte `0xef0100…` bytecode as a “wallet”, skipping `isApprovedContractRecipient`. Anyone could deploy a 23-byte contract mimicking EIP-7702 designation and receive PXT without multisig approval.

### What we shipped

`_isWallet` is now `code.length == 0` only. The EIP-7702 carve-out is removed — on-chain code cannot distinguish a delegated EOA from a 23-byte contract.

- **DEX payouts:** unchanged — `_enforceContractRecipient` skips the gate when `from == poolManager` (buys / LP exits to 7702-shaped recipients still work).
- **P2P to 7702 addresses:** requires one-time `setApprovedContractRecipient` via `RECIPIENT_APPROVER_ROLE`.
- **Seed dust refund:** `FeeCollector → owner()` allowed for one-shot `addLiquidity` leftovers (pre-renounce deployer may carry fork 7702 code).

Tests: `test_fake_7702_sized_contract_requires_allowlist`, `test_pool_manager_payout_to_7702_shaped_recipient`, `test_7702_shaped_recipient_allowed_after_multisig_approval`.

### Accepted residual risk (CREATE2)

`code.length == 0` also matches a CREATE2 address **before** the contract is deployed (pre-fund, then deploy). An unapproved contract could receive PXT that way. **Accepted:** impact is limited to routing tokens to a self-chosen contract address; it does not drain protocol custody or bypass DEX economics. Full on-chain EOA-vs-contract detection is not possible; we do not require allowlist for every EOA transfer.

---

## CCR — Contract Centralization Risk

| | |
|--|--|
| **Criticality** | Minor / Informative |
| **PDF** | `Pxt.sol`, `PhoenixV4ReturnDeltaHook.sol`, `PhoenixFeeCollector.sol` / `PhoenixBuyback.sol` |
| **Our status** | Accepted (by design); mitigated by mandatory pre-go-live lock |
| **Code** | N/A (operational ceremony: `LockProtocolReturnDelta`) |

### Finding

While `Ownable` is live, the deployer can change privileged configuration — e.g. `setWalletStatus` (FeeExempt / NoPenalty), `setPoolManager`, hook/collector wiring, buyback params, and (before one-shot setters fire) bootstrap addresses. That is centralization / admin trust during deployment and setup.

### Decision

**Acknowledged and by design.** Bootstrap requires a trusted deployer to mint supply, wire the official pool, seed LP, configure anti-bot, and run checks. **Production is not live until the lock ceremony completes:** `LockProtocolReturnDelta` renounces Ownable on **FeeCollector → Hook → Pxt** after verification (hook = attributor, fee wallets, collector address, buyback callers, etc.). After renounce, `owner == address(0)` on those three contracts — no deployer path to `setWalletStatus`, rotate one-shot wiring, or other owner-only setters.

Intentional **post-lock** governance remains on a multisig via AccessControl (not Ownable): `RECIPIENT_APPROVER_ROLE` on Pxt (`setApprovedContractRecipient`), `BUYBACK_EXECUTOR_APPROVER_ROLE` on FeeCollector (`setAuthorizedBuybackCaller`). That is limited ops governance, not full protocol centralization.

### Not done

No timelock on renounce itself; no on-chain “go-live” flag beyond `owner == 0` after the scripted ceremony. Trust the lock script + multisig handoff is executed before public trading.

### Residual risk

- **Pre-go-live only:** Until renounce, treat the deployer as trusted (see ST cross-ref). Do not open public trading before lock.
- Post-lock, multisig can still add/remove approved contract recipients and buyback callers — scoped roles by design, not owner takeover of sell lock or fee economics.

---

## EOIPF — Expected Output Ignores Pool Fees

| | |
|--|--|
| **Criticality** | Minor / Informative |
| **PDF** | `PhoenixBuyback.sol`, `PhoenixBuybackMath.sol` |
| **Our status** | Accepted (by design) |
| **Code** | N/A |

### Finding

`_executeBuybackCash` sizes `expectedPxt` via `pxtForQuote` at the frozen spot — a fee-free, zero-impact conversion. The auditor notes that a non-zero **Uniswap LP fee** would make that baseline optimistic vs `enforceMinOut`, so valid buybacks could revert on `Slippage()`.

### Decision

**Accepted.** The official pool is deployed with **LP fee = 0** by design (`PoolKey.fee == 0` at bootstrap). Protocol economics (2.7% buy/sell skims, burn, dump window) come from the **return-delta hook**, not from the v4 pool fee tier. FeeCollector **buyback swaps skip the hook buy skim** (`sender == feeCollector`), so buyback USDC is not taxed again on the way in.

`pxtForQuote` + `maxBuybackSlippageBps` + `sqrtPriceLimitX96` remain the on-chain guard: execution is bounded by the limit; keepers should still pass a quote-based `minPxtBought` when using a public mempool (see JLVE).

### Not done

No fee-aware v4 quoter inside `PhoenixBuyback`; no change to `pxtForQuote` / `enforceMinOut` for hypothetical non-zero LP fees.

### Residual risk

Large buybacks vs available liquidity can still hit `Slippage()` from **curve impact** (not LP fee). Mitigation is ops: smaller `usdcAmount`, wait for depth, or set `minPxtBought` from an off-chain quote. Default 2% slippage is sized for normal keeper flow on the seeded official pool.

---

## EORZ — Expected Output Rounds Zero

| | |
|--|--|
| **Criticality** | Minor / Informative |
| **PDF** | `PhoenixBuybackMath.sol` `pxtForQuote` / `enforceMinOut` |
| **Our status** | Resolved |
| **Code** | Working tree |

### Finding

In the PXT-as-token1 branch, `pxtForQuote` divided `sqrtPriceX96²` by `Q96` before multiplying by `quoteAmount`, truncating early and sometimes returning zero when the true amount was ≥ 1 base unit. When `expectedPxt == 0`, `enforceMinOut` only required `actual > 0` (no percentage floor if `minPxtBought == 0`).

### What we shipped

`pxtForQuote` uses one `FullMath.mulDiv` per branch (`quote × Q96² / price` or `quote × price / Q96²`). `enforceMinOut` reverts on `expected == 0` instead of accepting any nonzero output.

Tests: `PhoenixBuybackMath.t.sol` (auditor counterexample + enforceMinOut).

---

## FWEPE — Fixed Windows Enable Penalty Evasion

| | |
|--|--|
| **Criticality** | Minor / Informative |
| **PDF** | `PhoenixV4ReturnDeltaHook.sol` `_fairSellFeeBps` / `_applySellWindow` |
| **Our status** | Accepted (by design) |
| **Code** | N/A |

### Finding

Dump protection uses a **fixed 24h bucket** from the seller’s first sale in the window (`windowStart`, `soldInWindow`, `balanceAtWindowStart`). When the bucket expires, sold volume resets to zero and the denominator refreshes. A seller can sell ~10% of balance just before expiry and ~10% of the new balance just after, moving ~19% of the original position across the boundary at base sell fee (5.4%) instead of penalty (37.8%).

### Decision

**Accepted.** Rolling 24h logs or hourly buckets would add storage and gas on every sell for a bounded, timing-dependent edge case. The fixed window is intentional: simple on-chain accounting, clear UX (“first sell starts a 24h clock”), and penalty still applies to **>10% of the window-start balance within that bucket**. FBBP already addresses snapshot inflation (separate from this boundary reset).

### Not done

No rolling lookback, ring buffer of sell timestamps, or hourly bucket array.

### Residual risk

A patient seller can schedule two sells around the 24h boundary for slightly more than 10% of their original bag at base fee. Mitigation is economic (penalty on large single-window dumps) and monitoring, not elimination of calendar-boundary bursts.

---

## FAPR — Fresh Address Penalty Reset

| | |
|--|--|
| **Criticality** | Minor / Informative |
| **PDF** | `PhoenixV4ReturnDeltaHook.sol` `sellWindows` / `_fairSellFeeBps` |
| **Our status** | Accepted (by design) |
| **Code** | N/A |

### Finding

Dump-window state is keyed **per seller address**. A holder can sell ~10% from wallet A, transfer the rest to fresh wallet B, and get a new 10% allowance on B’s balance. Repeating across many wallets can push more than 10% of an original position through at base sell fee (5.4%) instead of penalty (37.8%).

### Decision

**Accepted.** Quota is intentionally **per-address** — no on-chain identity graph for fungible PXT. Splitting is self-limiting in one round: each new wallet only gets 10% of **its** balance at base tier; **selling 100% from a split wallet still triggers penalty** on that wallet. Moving the stack costs **2.7%** wallet transfer tax per hop (unless admin-tagged FeeExempt / NoPenalty). Multi-wallet extraction is many txs, repeated tax, and gas — not a free bypass of the penalty tier on a single large dump from one address.

### Not done

No transfer-window inheritance (`noteWalletTransfer`), inbound cooldown, or cross-wallet quota merge.

### Residual risk

Determined actors can chain split → sell 10% → transfer → repeat to liquidate over time at base tier plus transfer tax. Single-address dumps **>10% in 24h** remain penalized. See also **FWEPE** (calendar boundary within one address).
