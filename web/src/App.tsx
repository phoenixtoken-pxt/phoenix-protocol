import { Contract, formatUnits, type Signer } from "ethers";
import { useCallback, useEffect, useState } from "react";
import { PriceChart } from "./components/PriceChart";
import { ERC20_ABI, FEE_COLLECTOR_ABI, HOOK_ABI, ANTI_BOT_OPEN_SELL_ABI, PXT_ABI, assertConfig, config, explorerTxUrl } from "./contracts";
import { useSpotPrice } from "./hooks/useSpotPrice";
import {
  ANVIL_WALLETS,
  connectAnvilWallet,
  type AnvilWalletIndex,
} from "./lib/anvilWallet";
import { formatBal, formatUnix, parseAmount, shortAddr } from "./lib/format";
import { readLpFees, type LpFeeSnapshot } from "./lib/lpFees";
import { assertLocalDeploy, readProvider } from "./lib/providers";
import { quoteExactIn, type SwapQuote } from "./lib/quoteV4";
import { formatSpot } from "./lib/spotPrice";
import {
  readPxtClaimBalance,
  openTradingWithFirstSell,
  swapExactIn,
  transferPxt,
  type SettlementMode,
  type SwapDirection,
} from "./lib/swapV4";
import { readChainTimestamp, warpBySeconds, warpToSellUnlock } from "./lib/warpTime";
import "./App.css";

type Balances = { eth: bigint; pxt: bigint; musdc: bigint; pxtClaims: bigint };
type FeeBals = {
  donationPxt: bigint;
  marketingPxt: bigint;
  donationUsdc: bigint;
  marketingUsdc: bigint;
};

type PendingFees = {
  donationPxt: bigint;
  marketingPxt: bigint;
  burnPxt: bigint;
  buybackPxt: bigint;
  donationUsdc: bigint;
  marketingUsdc: bigint;
  burnUsdc: bigint;
  buybackUsdc: bigint;
};

type BuybackQuote = {
  usdcSpendable: bigint;
  positionLiquidity: bigint;
  recyclePxt: bigint;
  recycleTickLower: number;
  recycleTickUpper: number;
  recycleLiquidity: bigint;
};

type HookInfo = {
  antiBot: string;
  openSellOperator: string;
  cleared: boolean;
  sellUnlock: bigint;
  chainNow: number;
};

const EMPTY_BAL: Balances = { eth: 0n, pxt: 0n, musdc: 0n, pxtClaims: 0n };
const EMPTY_FEE: FeeBals = {
  donationPxt: 0n,
  marketingPxt: 0n,
  donationUsdc: 0n,
  marketingUsdc: 0n,
};
const EMPTY_PENDING: PendingFees = {
  donationPxt: 0n,
  marketingPxt: 0n,
  burnPxt: 0n,
  buybackPxt: 0n,
  donationUsdc: 0n,
  marketingUsdc: 0n,
  burnUsdc: 0n,
  buybackUsdc: 0n,
};
const EMPTY_BUYBACK: BuybackQuote = {
  usdcSpendable: 0n,
  positionLiquidity: 0n,
  recyclePxt: 0n,
  recycleTickLower: 0,
  recycleTickUpper: 0,
  recycleLiquidity: 0n,
};


function decodeErr(e: unknown): string {
  if (e && typeof e === "object") {
    const any = e as {
      shortMessage?: string;
      reason?: string;
      message?: string;
      data?: string;
      code?: string;
      info?: { error?: { data?: string; message?: string } };
      error?: { data?: string; message?: string };
      cause?: unknown;
    };

    const chunks: string[] = [
      any.data,
      any.info?.error?.data,
      any.error?.data,
      any.message,
      any.shortMessage,
      any.reason,
      any.info?.error?.message,
      any.error?.message,
      String(e),
    ]
      .filter(Boolean)
      .map((s) => String(s).toLowerCase());

    // Also walk nested cause / AggregateError-style payloads.
    if (any.cause) chunks.push(String(any.cause).toLowerCase());

    const blob = chunks.join(" ");

    // Custom error selectors (4-byte)
    if (blob.includes("1bbaf7d2")) return "Sells locked until sell unlock";
    if (blob.includes("728f34ff")) {
      return "Anti-bot: connect as Admin and use Open trading (clear + sell)";
    }
    if (blob.includes("f828947c")) {
      return "Insufficient PXT for dump surcharge — reduce sell size";
    }
    if (blob.includes("ef938641") || /nobuybackbudget/i.test(blob)) {
      return "No pending buyback budget — sell (or accrue dump fees) first";
    }
    if (blob.includes("e551180d") || /nosellfeepayoutbudget/i.test(blob)) {
      return "No pending PXT donation/marketing to redeem as USDC";
    }
    if (blob.includes("2c501976") || /buybacknotconfigured/i.test(blob)) {
      return "Buyback params not set on collector";
    }
    if (blob.includes("bb55fd27") || /insufficientliquidity/i.test(blob)) {
      return "Not enough removable protocol LP";
    }
    if (blob.includes("d64e375e") || /poolnotconfigured/i.test(blob)) {
      return "FeeCollector pool not configured";
    }
    if (blob.includes("e450d38c") || /erc20insufficientbalance/i.test(blob)) {
      return "Insufficient PXT balance for this transfer (check the connected wallet)";
    }
    if (blob.includes("fb8f41b2") || /erc20insufficientallowance/i.test(blob)) {
      return "Insufficient token allowance — approve first";
    }
    if (/deadlineexpired/i.test(blob)) return "Buyback deadline expired - retry";
    if (/slippage/i.test(blob)) return "Buyback slippage - try again";
    if (/sellslocked/i.test(blob)) return "Sells locked until sell unlock";
    if (/antibotsellblocked/i.test(blob)) {
      return "Anti-bot: connect as Admin and use Open trading (clear + sell)";
    }
    if (/insufficientpenaltybalance/i.test(blob)) {
      return "Insufficient PXT for dump surcharge — reduce sell size";
    }

    return any.shortMessage || any.reason || any.message || String(e);
  }
  return String(e);
}

export function App() {
  const [configError, setConfigError] = useState<string | null>(null);
  const [status, setStatus] = useState("Select an Anvil wallet to start.");
  const [statusKind, setStatusKind] = useState<"ok" | "error" | "">("");
  const [lastTxHash, setLastTxHash] = useState<string | null>(null);
  const [txCopied, setTxCopied] = useState(false);
  const [busy, setBusy] = useState(false);

  const [account, setAccount] = useState("");
  const [label, setLabel] = useState("");
  const [signer, setSigner] = useState<Signer | null>(null);
  const [walletIndex, setWalletIndex] = useState<AnvilWalletIndex>(4);

  const [balances, setBalances] = useState<Balances>(EMPTY_BAL);
  const [fees, setFees] = useState<FeeBals>(EMPTY_FEE);
  const [pending, setPending] = useState<PendingFees>(EMPTY_PENDING);
  const [buybackQuote, setBuybackQuote] = useState<BuybackQuote>(EMPTY_BUYBACK);
  const [lpFees, setLpFees] = useState<LpFeeSnapshot | null>(null);
  const [hook, setHook] = useState<HookInfo | null>(null);
  const [walletStatus, setWalletStatus] = useState<number | null>(null);
  /** Return-delta: USDC skim parked on hook after ERC-6909 claim sells. */
  const [orphanUsdcSkim, setOrphanUsdcSkim] = useState(0n);

  const [direction, setDirection] = useState<SwapDirection>("buy");
  const [settlement, setSettlement] = useState<SettlementMode>("wallet");
  const [amount, setAmount] = useState("100");
  const [quote, setQuote] = useState<SwapQuote | null>(null);
  const [quoteError, setQuoteError] = useState<string | null>(null);
  const [quoteLoading, setQuoteLoading] = useState(false);
  const [p2pTo, setP2pTo] = useState<string>(ANVIL_WALLETS[5].address);
  const [p2pAmount, setP2pAmount] = useState("100");
  const [buybackUsdcInput, setBuybackUsdcInput] = useState("");

  const { spot, history, loading: spotLoading, error: spotError, refresh: refreshSpot } =
    useSpotPrice(!configError);

  useEffect(() => {
    try {
      assertConfig();
      setConfigError(null);
    } catch (e) {
      setConfigError(e instanceof Error ? e.message : "Invalid config");
    }
  }, []);

  const refresh = useCallback(async (addr?: string) => {
    const who = addr || account;
    const pxt = new Contract(config.pxt, PXT_ABI, readProvider);
    const musdc = new Contract(config.quote, ERC20_ABI, readProvider);
    const hookC = new Contract(config.hook, HOOK_ABI, readProvider);
    const hasCollector =
      Boolean(config.feeCollector) && config.feeCollector !== "undefined";

    const [
      donationPxt,
      marketingPxt,
      donationUsdc,
      marketingUsdc,
      sellUnlock,
      antiBot,
      cleared,
      chainNow,
    ] = await Promise.all([
      pxt.balanceOf(config.donation) as Promise<bigint>,
      pxt.balanceOf(config.marketing) as Promise<bigint>,
      musdc.balanceOf(config.donation) as Promise<bigint>,
      musdc.balanceOf(config.marketing) as Promise<bigint>,
      pxt.sellUnlockTimestamp() as Promise<bigint>,
      hookC.antiBotSeller() as Promise<string>,
      hookC.sellProtectionCleared() as Promise<boolean>,
      readChainTimestamp(),
    ]);

    let openSellOperator = "";
    if (config.antiBotOpenSell && config.antiBotOpenSell !== "undefined") {
      try {
        const openSell = new Contract(config.antiBotOpenSell, ANTI_BOT_OPEN_SELL_ABI, readProvider);
        openSellOperator = (await openSell.operator()) as string;
      } catch {
        openSellOperator = "";
      }
    }

    setFees({ donationPxt, marketingPxt, donationUsdc, marketingUsdc });
    setHook({ antiBot, openSellOperator, cleared, sellUnlock, chainNow });

    try {
      const orphan = (await hookC.orphanSkim()) as [bigint, bigint, bigint, string];
      setOrphanUsdcSkim(orphan[2]);
    } catch {
      setOrphanUsdcSkim(0n);
    }

    if (hasCollector) {
      const collector = new Contract(config.feeCollector, FEE_COLLECTOR_ABI, readProvider);
      const [
        pendingPxt,
        pendingUsdc,
        qBuyback,
        recyclePxt,
        recycleTickLower,
        recycleTickUpper,
        recycleLiquidity,
      ] = await Promise.all([
        collector.pending(config.pxt) as Promise<[bigint, bigint, bigint, bigint]>,
        collector.pending(config.quote) as Promise<[bigint, bigint, bigint, bigint]>,
        collector.quoteBuyback() as Promise<[bigint, bigint]>,
        collector.recyclePxt() as Promise<bigint>,
        collector.lastRecycleTickLower() as Promise<number>,
        collector.lastRecycleTickUpper() as Promise<number>,
        collector.lastRecycleLiquidity() as Promise<bigint>,
      ]);
      setPending({
        donationPxt: pendingPxt[0],
        marketingPxt: pendingPxt[1],
        burnPxt: pendingPxt[2],
        buybackPxt: pendingPxt[3],
        donationUsdc: pendingUsdc[0],
        marketingUsdc: pendingUsdc[1],
        burnUsdc: pendingUsdc[2],
        buybackUsdc: pendingUsdc[3],
      });
      setBuybackQuote({
        usdcSpendable: qBuyback[0],
        positionLiquidity: qBuyback[1],
        recyclePxt,
        recycleTickLower: Number(recycleTickLower),
        recycleTickUpper: Number(recycleTickUpper),
        recycleLiquidity,
      });
    } else {
      setPending(EMPTY_PENDING);
      setBuybackQuote(EMPTY_BUYBACK);
    }

    try {
      setLpFees(await readLpFees());
    } catch {
      setLpFees(null);
    }

    if (who) {
      const [eth, pxtBal, musdcBal, pxtClaims, status] = await Promise.all([
        readProvider.getBalance(who),
        pxt.balanceOf(who) as Promise<bigint>,
        musdc.balanceOf(who) as Promise<bigint>,
        readPxtClaimBalance(who),
        pxt.walletStatus(who) as Promise<number>,
      ]);
      setBalances({ eth, pxt: pxtBal, musdc: musdcBal, pxtClaims });
      setWalletStatus(Number(status));
    }
  }, [account]);

  useEffect(() => {
    if (configError) return;
    void refresh();
    const id = window.setInterval(() => void refresh(), 8_000);
    return () => window.clearInterval(id);
  }, [configError, refresh]);

  useEffect(() => {
    if (configError) return;

    const trader = account || ANVIL_WALLETS[walletIndex].address;
    let cancelled = false;
    const handle = window.setTimeout(() => {
      void (async () => {
        setQuoteLoading(true);
        setQuoteError(null);
        try {
          const amt = parseAmount(amount, 6);
          const q = await quoteExactIn(direction, amt, trader, settlement);
          if (cancelled) return;
          setQuote(q);
          // Dump surcharge is extra ERC-20 PXT — claim burns skip the on-token dump path.
          if (
            settlement === "wallet" &&
            direction === "sell" &&
            q.extraPxtCost > 0n &&
            balances.pxt < q.amountIn + q.extraPxtCost
          ) {
            const need = q.amountIn + q.extraPxtCost;
            setQuoteError(
              `Dump sell needs ${formatBal(need)} PXT (swap ${formatBal(q.amountIn)} + dump ${formatBal(q.extraPxtCost)}); wallet has ${formatBal(balances.pxt)}. Sell at most ~75.5% of balance.`,
            );
          } else if (settlement === "claims" && direction === "sell" && balances.pxtClaims < q.amountIn) {
            setQuoteError(
              `Not enough PXT claims: need ${formatBal(q.amountIn)}, have ${formatBal(balances.pxtClaims)}. Buy with “Claims” settlement first.`,
            );
          } else {
            setQuoteError(null);
          }
        } catch (e) {
          if (!cancelled) {
            setQuote(null);
            setQuoteError(decodeErr(e));
          }
        } finally {
          if (!cancelled) setQuoteLoading(false);
        }
      })();
    }, 350);

    return () => {
      cancelled = true;
      window.clearTimeout(handle);
    };
  }, [
    configError,
    amount,
    direction,
    settlement,
    account,
    walletIndex,
    spot?.tick,
    balances.pxt,
    balances.pxtClaims,
  ]);

  async function onConnect(index: AnvilWalletIndex) {
    setBusy(true);
    setStatusKind("");
    try {
      await assertLocalDeploy();
      const { signer: s, account: a, label: l } = await connectAnvilWallet(index);
      setSigner(s);
      setAccount(a);
      setLabel(l);
      setWalletIndex(index);
      setStatus(`Connected ${l} (${shortAddr(a)})`);
      setStatusKind("ok");
      await refresh(a);
    } catch (e) {
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  async function onSwap() {
    if (!signer) return;
    if (!quote || quote.direction !== direction) {
      setStatus("Wait for quote to finish");
      setStatusKind("error");
      return;
    }
    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      const amt = quote.amountIn;
      setStatus(
        direction === "sell" && settlement === "wallet" && quote.extraPxtCost > 0n
          ? `Selling ${formatBal(amt)} PXT (+ ${formatBal(quote.extraPxtCost)} dump)...`
          : direction === "sell" && settlement === "claims"
            ? `Selling ${formatBal(amt)} PXT claims (burn)...`
            : direction === "buy" && settlement === "claims"
              ? `Buying ${amount} mUSDC → PXT claims...`
              : `${direction === "buy" ? "Buying" : "Selling"} ${amount}...`,
      );
      const hash = await swapExactIn(signer, direction, amt, settlement);
      setLastTxHash(hash);
      setTxCopied(false);
      setStatus("Swap ok");
      setStatusKind("ok");
      await refresh();
      await refreshSpot();
    } catch (e) {
      setLastTxHash(null);
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  async function onP2p() {
    if (!signer) return;
    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      const amt = parseAmount(p2pAmount, 6);
      const hash = await transferPxt(signer, p2pTo, amt);
      setLastTxHash(hash);
      setTxCopied(false);
      setStatus("P2P transfer ok (2.7% unless recipient is FeeExempt or NoPenalty)");
      setStatusKind("ok");
      await refresh();
      await refreshSpot();
    } catch (e) {
      setLastTxHash(null);
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }
  async function ensureSigner(): Promise<Signer> {
    if (signer) return signer;
    const { signer: s, account: a, label: l } = await connectAnvilWallet(0);
    setSigner(s);
    setAccount(a);
    setLabel(l);
    setWalletIndex(0);
    return s;
  }

  async function onCollect() {
    if (!config.feeCollector || config.feeCollector === "undefined") {
      setStatus("FeeCollector not configured");
      setStatusKind("error");
      return;
    }
    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      const s = await ensureSigner();
      setStatus("Collecting fees → donation / marketing / burn...");
      const collector = new Contract(config.feeCollector, FEE_COLLECTOR_ABI, s);
      const tx = await collector.collect();
      const receipt = await tx.wait();
      setLastTxHash(receipt.hash as string);
      setTxCopied(false);
      setStatus("Collect ok - fees distributed (buyback stays pending)");
      setStatusKind("ok");
      await refresh();
      await refreshSpot();
    } catch (e) {
      setLastTxHash(null);
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  async function onFinalizeOrphanedSell() {
    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      const s = await ensureSigner();
      if (orphanUsdcSkim === 0n) {
        setStatus("No orphaned claim-sell skim on hook");
        setStatusKind("ok");
        await refresh();
        return;
      }
      setStatus(`Finalizing orphaned skim (~${formatBal(orphanUsdcSkim)} mUSDC) → FeeCollector...`);
      const hookC = new Contract(config.hook, HOOK_ABI, s);
      const tx = await hookC.finalizeOrphanedSell();
      const receipt = await tx.wait();
      setLastTxHash(receipt.hash as string);
      setTxCopied(false);
      setStatus("Orphan skim accrued to FeeCollector pending — Collect / Buyback ready");
      setStatusKind("ok");
      await refresh();
      await refreshSpot();
    } catch (e) {
      setLastTxHash(null);
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  async function onBuyback() {
    if (!config.feeCollector || config.feeCollector === "undefined") {
      setStatus("FeeCollector not configured");
      setStatusKind("error");
      return;
    }
    const maxUsdc =
      buybackQuote.usdcSpendable > 0n ? buybackQuote.usdcSpendable : pending.buybackUsdc;
    const hasBudget = pending.buybackPxt > 0n || pending.buybackUsdc > 0n || maxUsdc > 0n;
    if (!hasBudget) {
      setStatus("No pending buyback budget — sell (or accrue dump fees) first");
      setStatusKind("error");
      return;
    }

    let usdcAmount = 0n;
    const trimmed = buybackUsdcInput.trim();
    if (trimmed) {
      try {
        usdcAmount = parseAmount(trimmed, 6);
      } catch {
        setStatus("Enter a valid mUSDC buyback amount");
        setStatusKind("error");
        return;
      }
      if (usdcAmount === 0n) {
        setStatus("Buyback amount must be positive (or clear the field for full budget)");
        setStatusKind("error");
        return;
      }
      if (maxUsdc > 0n && usdcAmount > maxUsdc) {
        setStatus(`Amount exceeds available ~${formatBal(maxUsdc)} mUSDC`);
        setStatusKind("error");
        return;
      }
    }

    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      const s = await ensureSigner();
      setStatus(
        `Executing buyback${usdcAmount > 0n ? ` (${formatBal(usdcAmount)} mUSDC)` : " (full cash budget)"}...`,
      );
      const collector = new Contract(config.feeCollector, FEE_COLLECTOR_ABI, s);
      const chainNow = await readChainTimestamp();
      const deadline = BigInt(chainNow + 600);
      // Prefer quote-based minPxtBought for production keepers; 0 still uses protocol maxBuybackSlippageBps vs spot.
      const tx = await collector.executeBuyback(usdcAmount, 0n, deadline);
      const receipt = await tx.wait();
      setLastTxHash(receipt.hash as string);
      setTxCopied(false);
      setStatus("Buyback ok - PXT deposited as single-sided LP above spot");
      setStatusKind("ok");
      setBuybackUsdcInput("");
      await refresh();
      await refreshSpot();
    } catch (e) {
      setLastTxHash(null);
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  async function onWarp(kind: "unlock" | "1d" | "1h") {
    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      let now: number;
      if (kind === "unlock" && hook) {
        now = await warpToSellUnlock(hook.sellUnlock);
      } else if (kind === "1d") {
        now = await warpBySeconds(86400);
      } else {
        now = await warpBySeconds(3600);
      }
      setStatus(`Warped chain time → ${formatUnix(now)}`);
      setStatusKind("ok");
      await refresh();
    } catch (e) {
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  async function onOpenTrading() {
    if (!hook) return;
    const zero = "0x0000000000000000000000000000000000000000";
    if (hook.antiBot === zero || hook.cleared) {
      setStatus(hook.cleared ? "Public sells already open" : "Anti-bot is off");
      setStatusKind("ok");
      return;
    }
    if (sellsLocked) {
      setStatus("Warp to sell unlock before opening trading");
      setStatusKind("error");
      return;
    }
    if (!config.antiBotOpenSell || config.antiBotOpenSell === "undefined") {
      setStatus("VITE_ANTI_BOT_OPEN_SELL missing — re-run make bootstrap-anvil");
      setStatusKind("error");
      return;
    }
    const who = (account || "").toLowerCase();
    const op = (hook.openSellOperator || "").toLowerCase();
    if (!who || !op || who !== op) {
      setStatus(
        `Connect as openSell operator (${op ? shortAddr(hook.openSellOperator) : "?"}) — usually Admin`,
      );
      setStatusKind("error");
      return;
    }

    let amt: bigint;
    try {
      amt = parseAmount(amount, 6);
    } catch {
      setStatus("Enter a valid PXT amount (Trade panel) for the ceremonial first sell");
      setStatusKind("error");
      return;
    }
    if (amt === 0n) {
      setStatus("Ceremonial sell amount must be > 0");
      setStatusKind("error");
      return;
    }

    setBusy(true);
    setStatusKind("");
    setLastTxHash(null);
    try {
      const s = await ensureSigner();
      setStatus(`Opening trading: clear + sell ${formatBal(amt)} PXT (atomic)...`);
      const hash = await openTradingWithFirstSell(s, amt);
      setLastTxHash(hash);
      setTxCopied(false);
      setStatus("Trading open — operator sold via openSell helper; anyone may sell / buyback");
      setStatusKind("ok");
      await refresh();
      await refreshSpot();
    } catch (e) {
      setLastTxHash(null);
      setStatus(decodeErr(e));
      setStatusKind("error");
    } finally {
      setBusy(false);
    }
  }

  const sellsLocked = hook ? hook.chainNow < Number(hook.sellUnlock) : true;
  const antiBotOff =
    !hook || hook.antiBot === "0x0000000000000000000000000000000000000000";
  const canClearAntiBot =
    Boolean(hook) &&
    !antiBotOff &&
    !hook!.cleared &&
    !sellsLocked &&
    Boolean(account) &&
    Boolean(hook!.openSellOperator) &&
    account.toLowerCase() === hook!.openSellOperator.toLowerCase() &&
    Boolean(config.antiBotOpenSell) &&
    config.antiBotOpenSell !== "undefined";
  const statusLabel =
    walletStatus === 1 ? "FeeExempt" : walletStatus === 2 ? "NoPenalty" : walletStatus === 0 ? "Normal" : "-";
  const hasFeeCollector = Boolean(config.feeCollector) && config.feeCollector !== "undefined";
  const buybackUsdcMax =
    buybackQuote.usdcSpendable > 0n ? buybackQuote.usdcSpendable : pending.buybackUsdc;
  const canBuyback =
    hasFeeCollector &&
    (pending.buybackPxt > 0n || pending.buybackUsdc > 0n || buybackUsdcMax > 0n);

  function setBuybackPct(pct: number) {
    if (buybackUsdcMax === 0n) return;
    const amt = (buybackUsdcMax * BigInt(pct)) / 100n;
    setBuybackUsdcInput(formatUnits(amt, 6));
  }

  if (configError) {
    return (
      <div className="app">
        <h1 className="brand">
          Phoenix <span>V4</span>
        </h1>
        <p className="status error">{configError}</p>
      </div>
    );
  }

  return (
    <div className="app">
      <header className="hero">
        <div>
          <h1 className="brand">
            Phoenix <span>V4</span>
          </h1>
        </div>
        <div className="row">
          <span className={`pill ${sellsLocked ? "warn" : "ok"}`}>
            {sellsLocked ? "Sells locked" : "Sells open"}
          </span>
          {hook && (
            <span className={`pill ${hook.cleared ? "ok" : "warn"}`}>
              Anti-bot {hook.cleared ? "cleared" : "active"}
            </span>
          )}
        </div>
      </header>

      <section className="panel" style={{ marginBottom: 16 }}>
        <h2>Anvil wallets</h2>
        <div className="wallet-grid">
          {ANVIL_WALLETS.slice(0, 4).map((w, i) => (
            <button
              key={w.address}
              type="button"
              className={`wallet-card ${walletIndex === i && account ? "active" : ""}`}
              disabled={busy}
              onClick={() => void onConnect(i as AnvilWalletIndex)}
            >
              <strong>{w.label}</strong>
              <small>{shortAddr(w.address)}</small>
              {w.note ? <small>{w.note}</small> : null}
            </button>
          ))}
        </div>
        <div className="wallet-grid" style={{ marginTop: 8 }}>
          {ANVIL_WALLETS.slice(4).map((w, i) => {
            const index = (i + 4) as AnvilWalletIndex;
            return (
              <button
                key={w.address}
                type="button"
                className={`wallet-card ${walletIndex === index && account ? "active" : ""}`}
                disabled={busy}
                onClick={() => void onConnect(index)}
              >
                <strong>{w.label}</strong>
                <small>{shortAddr(w.address)}</small>
                {w.note ? <small>{w.note}</small> : null}
              </button>
            );
          })}
        </div>
        {account && (
          <p className="hint" style={{ marginTop: 10 }}>
            Active: <strong>{label}</strong> · {account} · status {statusLabel}
          </p>
        )}
      </section>

      <PriceChart
        history={history}
        price={spot?.price ?? null}
        tick={spot?.tick ?? null}
        loading={spotLoading}
        error={spotError}
        pxtReserve={spot?.pxtReserve ?? null}
        musdcReserve={spot?.musdcReserve ?? null}
        liquidity={spot?.liquidity ?? null}
      />

      <div className="grid">
        <div className="stack">
          <section className="panel">
            <h2>Balances</h2>
            <div className="balances">
              <div className="bal">
                <div className="label">ETH</div>
                <div className="value">{formatBal(balances.eth, 18)}</div>
              </div>
              <div className="bal">
                <div className="label">PXT</div>
                <div className="value">{formatBal(balances.pxt)}</div>
              </div>
              <div className="bal">
                <div className="label">PXT claims</div>
                <div className="value">{formatBal(balances.pxtClaims)}</div>
              </div>
              <div className="bal">
                <div className="label">mUSDC</div>
                <div className="value">{formatBal(balances.musdc)}</div>
              </div>
            </div>
          </section>

          <section className="panel">
            <h2>V4 swap</h2>
            <div className="stack">
              <div className="seg">
                <button
                  type="button"
                  className={direction === "buy" ? "active" : ""}
                  onClick={() => setDirection("buy")}
                >
                  Buy PXT
                </button>
                <button
                  type="button"
                  className={direction === "sell" ? "active" : ""}
                  onClick={() => setDirection("sell")}
                >
                  Sell PXT
                </button>
              </div>
              <div className="seg">
                <button
                  type="button"
                  className={settlement === "wallet" ? "active" : ""}
                  onClick={() => setSettlement("wallet")}
                >
                  Wallet (ERC-20)
                </button>
                <button
                  type="button"
                  className={settlement === "claims" ? "active" : ""}
                  onClick={() => setSettlement("claims")}
                >
                  Claims (ERC-6909)
                </button>
              </div>
              <label>
                Amount ({direction === "buy" ? "mUSDC in" : "PXT into pool"})
                <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
                {settlement === "claims" ? (
                  <p className="hint" style={{ marginTop: 6 }}>
                    {direction === "buy"
                      ? "Output is minted as PoolManager PXT claims (not ERC-20). Sell those claims later with Claims settlement."
                      : "Burns PXT claims via PoolSwapTest. Skips ERC-20 attributeSell — always full penalty USDC skim (37.8%), then Refresh to accrue."}
                  </p>
                ) : null}
              </label>

              <div className="quote-box">
                <div className="label">Quote</div>
                {quoteLoading && !quote ? (
                  <div className="value muted">Quoting...</div>
                ) : quoteError && !quote ? (
                  <div className="value bad">{quoteError}</div>
                ) : quote ? (
                  <>
                    {quoteError ? <div className="value bad">{quoteError}</div> : null}
                    <dl className="quote-kv">
                      <dt>Price</dt>
                      <dd>{formatSpot(quote.spotPrice)} mUSDC / PXT</dd>
                      <>
                          <dt>You pay</dt>
                          <dd>
                            {formatBal(quote.amountIn)}{" "}
                            {settlement === "claims" && quote.direction === "sell"
                              ? "PXT claims"
                              : quote.tokenInSymbol}
                          </dd>
                        </>
                      <dt>Would get (no tax)</dt>
                      <dd>
                        {formatBal(quote.grossOut)}{" "}
                        {settlement === "claims" && quote.direction === "buy"
                          ? "PXT claims"
                          : quote.tokenOutSymbol}
                      </dd>
                      {quote.direction === "buy" ? (
                        <>
                          <dt>Donation (1.45% USDC)</dt>
                          <dd>
                            {quote.feeTier === "buy"
                              ? `−${formatBal(quote.buySplit.donationUsdc)} mUSDC`
                              : "-"}
                          </dd>
                          <dt>Marketing (1.25% USDC)</dt>
                          <dd>
                            {quote.feeTier === "buy"
                              ? `−${formatBal(quote.buySplit.marketingUsdc)} mUSDC`
                              : "-"}
                          </dd>
                        </>
                      ) : (
                        <>
                          <dt>Donation (1.25% USDC)</dt>
                          <dd>
                            {quote.feeTier === "sell" || quote.feeTier === "penalty"
                              ? `−${formatBal(quote.sellSplit.donationUsdc)} mUSDC`
                              : "-"}
                          </dd>
                          <dt>Marketing (1.15% USDC)</dt>
                          <dd>
                            {quote.feeTier === "sell" || quote.feeTier === "penalty"
                              ? `−${formatBal(quote.sellSplit.marketingUsdc)} mUSDC`
                              : "-"}
                          </dd>
                          <dt>Burn (1.85% PXT)</dt>
                          <dd>
                            {quote.sellSplit.burnPxt > 0n
                              ? `−${formatBal(quote.sellSplit.burnPxt)} PXT`
                              : "-"}
                          </dd>
                          <dt>
                            Buyback (
                            {quote.feeTier === "penalty" ? "33.55%" : "1.15%"} USDC)
                          </dt>
                          <dd>
                            {quote.feeTier === "sell" || quote.feeTier === "penalty"
                              ? `−${formatBal(quote.sellSplit.buybackUsdc)} mUSDC`
                              : "-"}
                          </dd>
                          {quote.feeTier === "penalty" ? (
                            <>
                              <dt>Tier</dt>
                              <dd>Penalty 37.8%</dd>
                            </>
                          ) : null}
                        </>
                      )}
                      <dt>
                        You receive (
                        {settlement === "claims" && quote.direction === "buy" ? "claims" : "mUSDC"})
                      </dt>
                      <dd className="quote-net">
                        {formatBal(quote.amountOut)}{" "}
                        {settlement === "claims" && quote.direction === "buy"
                          ? "PXT claims"
                          : quote.tokenOutSymbol}
                        {quoteLoading ? <span className="hint"> · updating...</span> : null}
                      </dd>
                    </dl>
                    <p className="hint">
                      V4 Quoter · tax for{" "}
                      {account ? label || shortAddr(account) : ANVIL_WALLETS[walletIndex].label}
                      {walletStatus === 1 ? " (FeeExempt)" : ""}
                      {settlement === "claims"
                        ? " · claims settlement"
                        : quote.feeTier === "penalty"
                          ? " · selling >10% of window balance triggers dump buyback"
                          : ""}
                    </p>
                  </>
                ) : (
                  <div className="value muted">-</div>
                )}
              </div>

              <p className="hint">
                Buy/sell fees skimmed in USDC (plus 1.85% PXT burn on sells), accrued on FeeCollector until Collect / Buyback. Dump window uses pessimistic USDC penalty + same-tx rebate. P2P transfer tax 2.7% unless recipient is FeeExempt or NoPenalty.{" "}
                Settlement: Wallet uses ERC-20; Claims uses PoolManager ERC-6909 (buy mint / sell burn). Claim sells skip ERC-20 attribution. After unlock, Admin must Open trading (clear + sell) before anyone (or 6909) can sell. Prefer Tester #5+ for
                taxed trades. Buys auto-mint mUSDC if needed.
              </p>
              <button
                type="button"
                className="btn btn-primary"
                disabled={!signer || busy || Boolean(quoteError)}
                onClick={() => void onSwap()}
              >
                {direction === "buy" ? "Buy" : "Sell"}
                {settlement === "claims" ? " (claims)" : ""}
              </button>
            </div>
          </section>

          <section className="panel">
            <h2>P2P transfer (token 2.7%)</h2>
            <div className="stack">
              <label>
                To
                <input value={p2pTo} onChange={(e) => setP2pTo(e.target.value)} />
              </label>
              <label>
                PXT amount
                <input
                  value={p2pAmount}
                  onChange={(e) => setP2pAmount(e.target.value)}
                  inputMode="decimal"
                />
              </label>
              <button
                type="button"
                className="btn"
                disabled={!signer || busy}
                onClick={() => void onP2p()}
              >
                Send PXT
              </button>
            </div>
          </section>
        </div>

        <div className="stack">
          <section className="panel">
            <h2>Fee wallets</h2>
            <dl className="kv">
              <dt>Donation</dt>
              <dd>
                {formatBal(fees.donationPxt)} PXT · {formatBal(fees.donationUsdc)} mUSDC
              </dd>
              <dt>Marketing</dt>
              <dd>
                {formatBal(fees.marketingPxt)} PXT · {formatBal(fees.marketingUsdc)} mUSDC
              </dd>
            </dl>
            <p className="hint" style={{ marginTop: 10 }}>
              Wallet balances update after Collect (permissionless). Fees accrue on FeeCollector first.{" "}
              {shortAddr(config.donation)} / {shortAddr(config.marketing)}
            </p>
          </section>

          <section className="panel">
            <h2>FeeCollector</h2>
            <dl className="kv">
                {lpFees ? (
                  <>
                    <dt>Uncollected in pool</dt>
                    <dd>
                      {formatBal(lpFees.feesPxt)} PXT · {formatBal(lpFees.feesMusdc)} mUSDC
                    </dd>
                  </>
                ) : null}
                <dt>Pending donation</dt>
                <dd>
                  {formatBal(pending.donationPxt)} PXT · {formatBal(pending.donationUsdc)} mUSDC
                </dd>
                <dt>Pending marketing</dt>
                <dd>
                  {formatBal(pending.marketingPxt)} PXT · {formatBal(pending.marketingUsdc)} mUSDC
                </dd>
                <dt>Pending burn</dt>
                <dd>
                  {formatBal(pending.burnPxt)} PXT · {formatBal(pending.burnUsdc)} mUSDC
                </dd>
                <dt>Pending buyback</dt>
                <dd>
                  {formatBal(pending.buybackPxt)} PXT · {formatBal(pending.buybackUsdc)} mUSDC
                </dd>
                <dt>Buyback USDC spendable</dt>
                <dd>{formatBal(buybackQuote.usdcSpendable)} mUSDC</dd>
                <dt>Recycle PXT (in LP)</dt>
                <dd>{formatBal(buybackQuote.recyclePxt)} PXT</dd>
                <dt>Orphan skim (hook)</dt>
                <dd>
                  {formatBal(orphanUsdcSkim)} mUSDC
                  {orphanUsdcSkim > 0n ? (
                    <span className="hint"> — claim sell; Refresh to accrue</span>
                  ) : null}
                </dd>
                <dt>Recycle band</dt>
                <dd className="mono">
                  [{buybackQuote.recycleTickLower}, {buybackQuote.recycleTickUpper}] · L=
                  {buybackQuote.recycleLiquidity.toString()}
                </dd>
                <dt>Collector</dt>
                <dd className="mono">{shortAddr(config.feeCollector)}</dd>
              </dl>
            <div className="buyback-controls" style={{ marginTop: 12 }}>
              <label className="buyback-amount">
                Buyback mUSDC
                <input
                  value={buybackUsdcInput}
                  onChange={(e) => setBuybackUsdcInput(e.target.value)}
                  placeholder={
                    buybackUsdcMax > 0n ? `max ${formatBal(buybackUsdcMax)}` : "no budget"
                  }
                  inputMode="decimal"
                  disabled={!canBuyback || busy}
                />
              </label>
              <div className="pct-row" role="group" aria-label="Buyback percent of available">
                {([25, 50, 75, 100] as const).map((pct) => (
                  <button
                    key={pct}
                    type="button"
                    className="btn btn-ghost pct-btn"
                    disabled={!canBuyback || busy || buybackUsdcMax === 0n}
                    onClick={() => setBuybackPct(pct)}
                  >
                    {pct}%
                  </button>
                ))}
              </div>
            </div>
            <div className="row" style={{ marginTop: 10 }}>
              <button
                type="button"
                className="btn"
                disabled={busy}
                onClick={() => void onFinalizeOrphanedSell()}
                title="Call finalizeOrphanedSell — move claim-sell USDC skim from hook into FeeCollector pending"
              >
                Refresh
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy || !hasFeeCollector}
                onClick={() => void onCollect()}
                title="Pay accrued USDC donation/marketing + burn PXT if any"
              >
                Collect
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy || !canBuyback}
                onClick={() => void onBuyback()}
                title={
                  !hasFeeCollector
                    ? "FeeCollector required"
                    : !canBuyback
                      ? "No pending buyback budget"
                      : buybackUsdcInput.trim()
                        ? `Spend ${buybackUsdcInput.trim()} mUSDC`
                        : `Spend full available ~${formatBal(buybackUsdcMax)} mUSDC`
                }
              >
                Buyback
              </button>
            </div>
            <p className="hint" style={{ marginTop: 10 }}>
              After a claims (ERC-6909) sell, USDC skim sits on the hook until Refresh (finalizeOrphanedSell). Then Collect pays donation / marketing; set buyback mUSDC (or %); leave empty for full cash budget. Protocol buyback skips the 2.7% buy skim.
            </p>
          </section>

          <section className="panel">
            <h2>Hook / unlock</h2>
            {hook ? (
              <dl className="kv">
                <dt>Chain time</dt>
                <dd>{formatUnix(hook.chainNow)}</dd>
                <dt>Sell unlock</dt>
                <dd>{formatUnix(hook.sellUnlock)}</dd>
                <dt>Anti-bot seller</dt>
                <dd>{hook.antiBot === "0x0000000000000000000000000000000000000000" ? "off" : shortAddr(hook.antiBot)}</dd>
                <dt>Open-sell operator</dt>
                <dd>{hook.openSellOperator ? shortAddr(hook.openSellOperator) : "-"}</dd>
                <dt>Protection cleared</dt>
                <dd>{hook.cleared ? "yes" : "no"}</dd>
                <dt>Hook</dt>
                <dd>{shortAddr(config.hook)}</dd>
              </dl>
            ) : (
              <p className="hint">Loading...</p>
            )}
            <div className="row" style={{ marginTop: 12 }}>
              <button type="button" className="btn" disabled={busy} onClick={() => void onWarp("1h")}>
                +1h
              </button>
              <button type="button" className="btn" disabled={busy} onClick={() => void onWarp("1d")}>
                +1d
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy || !hook}
                onClick={() => void onWarp("unlock")}
              >
                Warp to unlock
              </button>
              <button
                type="button"
                className="btn btn-primary"
                disabled={busy || !canClearAntiBot}
                onClick={() => void onOpenTrading()}
                title={
                  antiBotOff || hook?.cleared
                    ? "Public sells already open / anti-bot off"
                    : sellsLocked
                      ? "Warp to unlock first"
                      : !account ||
                          !hook?.openSellOperator ||
                          account.toLowerCase() !== hook.openSellOperator.toLowerCase()
                        ? `Connect as operator (${hook?.openSellOperator ? shortAddr(hook.openSellOperator) : "?"})`
                        : !config.antiBotOpenSell || config.antiBotOpenSell === "undefined"
                          ? "Missing VITE_ANTI_BOT_OPEN_SELL — re-sync web/.env / restart web-dev"
                          : `Atomic clear + sell ${amount || "?"} PXT (amount from Trade panel)`
                }
              >
                Open trading (clear + sell)
              </button>
            </div>
            <p className="hint" style={{ marginTop: 10 }}>
              After unlock, hooks block all sells (ERC-20 and ERC-6909) until the operator opens trading.
              Open trading runs clearSellProtection + operator&apos;s first sell in one transaction
              (openSell helper is on-chain antiBotSeller; no tx.origin).
              Amount comes from the Trade panel. If the sell fails, the market stays closed.
            </p>
          </section>

          <section className="panel">
            <h2>Addresses</h2>
            <dl className="kv">
              <dt>PXT</dt>
              <dd className="mono">{shortAddr(config.pxt)}</dd>
              <dt>mUSDC</dt>
              <dd className="mono">{shortAddr(config.quote)}</dd>
              <dt>PoolManager</dt>
              <dd className="mono">{shortAddr(config.poolManager)}</dd>
              <dt>PoolSwapTest</dt>
              <dd className="mono">{shortAddr(config.poolSwapTest)}</dd>
            </dl>
          </section>
        </div>
      </div>

      <div className={`status ${statusKind}`}>
        <div className="status-row">
          <span>{status}</span>
          {lastTxHash ? (
            <>
              {" · "}
              <a
                className="tx-link"
                href={explorerTxUrl(lastTxHash)}
                target="_blank"
                rel="noopener noreferrer"
              >
                View in explorer
              </a>
            </>
          ) : null}
        </div>
        {lastTxHash ? (
          <div className="tx-hash-row">
            <code className="tx-hash mono">{lastTxHash}</code>
            <button
              type="button"
              className="btn btn-ghost tx-copy"
              onClick={() => {
                void navigator.clipboard.writeText(lastTxHash).then(() => {
                  setTxCopied(true);
                  window.setTimeout(() => setTxCopied(false), 1500);
                });
              }}
            >
              {txCopied ? "Copied" : "Copy"}
            </button>
          </div>
        ) : null}
      </div>
    </div>
  );
}
