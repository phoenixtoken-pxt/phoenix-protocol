import { AbiCoder, Contract } from "ethers";
import { HOOK_ABI, PXT_ABI, STATE_VIEW_ABI, config } from "../contracts";
import { formatSpot, musdcPerPxt, poolIdFromKey } from "./spotPrice";
import { readProvider } from "./providers";
import { buildPoolKey, zeroForOne, type SettlementMode, type SwapDirection, type SwapExactness } from "./swapV4";

const QUOTER_ABI = [
  "function quoteExactInputSingle(((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) params) returns (uint256 amountOut, uint256 gasEstimate)",
  "function quoteExactOutputSingle(((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData) params) returns (uint256 amountIn, uint256 gasEstimate)",
] as const;

const BPS = 10_000n;
const BUY_FEE_BPS = 270n;
const BUY_DONATION_BPS = 145n;
const BUY_MARKETING_BPS = 125n;
const SELL_FEE_BPS = 540n;
const PENALTY_FEE_BPS = 3_780n;
/** Dump surcharge when LP fee already charged: 37.8% − 5.4%. */
const PENALTY_SURCHARGE_BPS = PENALTY_FEE_BPS - SELL_FEE_BPS;
const PENALTY_THRESHOLD_BPS = 1_000n;
const PENALTY_WINDOW = 86_400n; // 24h

const SELL_DONATION_BPS = 125n;
const SELL_MARKETING_BPS = 115n;
const SELL_BURN_BPS = 185n;
const SELL_BUYBACK_BPS = 115n;

const PENALTY_DONATION_BPS = 125n;
const PENALTY_MARKETING_BPS = 115n;
const PENALTY_BURN_BPS = 185n;
const PENALTY_BUYBACK_BPS = 3_355n;

/** USDC skim bps (burn is separate on PXT). */
const SELL_USDC_SKIM_BPS = SELL_DONATION_BPS + SELL_MARKETING_BPS + SELL_BUYBACK_BPS; // 355
const PENALTY_USDC_SKIM_BPS = PENALTY_DONATION_BPS + PENALTY_MARKETING_BPS + PENALTY_BUYBACK_BPS; // 3595

export type FeeTier = "none" | "buy" | "sell" | "penalty";

export type BuyFeeSplit = {
  donationUsdc: bigint;
  marketingUsdc: bigint;
};

/** USDC skims + mid-swap PXT burn. */
export type SellFeeSplit = {
  mode: "return-delta";
  donationUsdc: bigint;
  marketingUsdc: bigint;
  burnPxt: bigint;
  buybackUsdc: bigint;
};

export type SwapQuote = {
  direction: SwapDirection;
  exactness: SwapExactness;
  /** Exact-in: you pay this. Exact-out: quoted input (PXT on sell, mUSDC on buy). */
  amountIn: bigint;
  /** Typed specified amount (input for exact-in, output for exact-out). */
  specifiedAmount: bigint;
  /** Total PXT leaving the wallet (= amountIn + extraPxtCost). */
  walletPxtOut: bigint;
  /** Spot mUSDC per 1 PXT */
  spotPrice: number;
  /** Estimated pool out with zero Phoenix tax (burn/skim reversed from Quoter). */
  grossOut: bigint;
  buySplit: BuyFeeSplit;
  sellSplit: SellFeeSplit;
  feeBps: bigint;
  feeTier: FeeTier;
  /** Expected token out after Phoenix tax (and exact-out ERC-20 rebate). */
  amountOut: bigint;
  /** Extra PXT debited beyond amountIn (0 for current hook). */
  extraPxtCost: bigint;
  /** Exact-out only: old `net × bps / 10000` USDC fee (RIFM undercharge). */
  legacyFeeUsdc: bigint;
  /** Exact-out only: USDC fee after gross-up. */
  nowFeeUsdc: bigint;
  tokenInSymbol: "PXT" | "mUSDC";
  tokenOutSymbol: "PXT" | "mUSDC";
  gasEstimate: bigint;
  hookMode: "return-delta";
};

const EMPTY_BUY_SPLIT: BuyFeeSplit = { donationUsdc: 0n, marketingUsdc: 0n };

const EMPTY_SELL: SellFeeSplit = {
  mode: "return-delta",
  donationUsdc: 0n,
  marketingUsdc: 0n,
  burnPxt: 0n,
  buybackUsdc: 0n,
};

async function quoterExactIn(direction: SwapDirection, amountIn: bigint, trader: string): Promise<{
  amountOut: bigint;
  gasEstimate: bigint;
}> {
  const key = buildPoolKey();
  const zfo = zeroForOne(direction, key);
  const hookData = AbiCoder.defaultAbiCoder().encode(["address"], [trader]);
  const quoter = new Contract(config.quoter, QUOTER_ABI, readProvider);
  const [amountOut, gasEstimate] = (await quoter.quoteExactInputSingle.staticCall({
    poolKey: key,
    zeroForOne: zfo,
    exactAmount: amountIn,
    hookData,
  })) as [bigint, bigint];
  return { amountOut, gasEstimate };
}

async function quoterExactOut(direction: SwapDirection, amountOut: bigint, trader: string): Promise<{
  amountIn: bigint;
  gasEstimate: bigint;
}> {
  const key = buildPoolKey();
  const zfo = zeroForOne(direction, key);
  const hookData = AbiCoder.defaultAbiCoder().encode(["address"], [trader]);
  const quoter = new Contract(config.quoter, QUOTER_ABI, readProvider);
  const [amountIn, gasEstimate] = (await quoter.quoteExactOutputSingle.staticCall({
    poolKey: key,
    zeroForOne: zfo,
    exactAmount: amountOut,
    hookData,
  })) as [bigint, bigint];
  return { amountIn, gasEstimate };
}

/** Fee `f` such that `f / (net + f) == bps / BPS` (exact-out / RIFM). */
function grossUp(net: bigint, bps: bigint): bigint {
  if (bps === 0n || net === 0n || bps >= BPS) return 0n;
  return (net * bps) / (BPS - bps);
}

/** Invert `net = gross * (BPS - feeBps) / BPS` (floor). */
function reverseFee(net: bigint, feeBps: bigint): bigint {
  if (net === 0n || feeBps === 0n || feeBps >= BPS) return net;
  return (net * BPS) / (BPS - feeBps);
}

function applyFee(gross: bigint, feeBps: bigint): bigint {
  if (gross === 0n || feeBps === 0n) return gross;
  return (gross * (BPS - feeBps)) / BPS;
}

function previewSellFeeBps(args: {
  walletStatus: number;
  amountIn: bigint;
  balance: bigint;
  windowStart: bigint;
  soldInWindow: bigint;
  balanceAtStart: bigint;
  now: number;
}): { feeBps: bigint; feeTier: FeeTier } {
  // 1 = FeeExempt, 2 = NoPenalty, 0 = Normal
  if (args.walletStatus === 1) return { feeBps: 0n, feeTier: "none" };
  if (args.walletStatus === 2) return { feeBps: SELL_FEE_BPS, feeTier: "sell" };

  let soldInWindow = args.soldInWindow;
  let balanceAtStart = args.balanceAtStart;
  if (
    args.windowStart === 0n ||
    BigInt(args.now) >= args.windowStart + PENALTY_WINDOW
  ) {
    soldInWindow = 0n;
    balanceAtStart = args.balance;
  }

  const newSold = soldInWindow + args.amountIn;
  const penalized =
    balanceAtStart > 0n && newSold * BPS > balanceAtStart * PENALTY_THRESHOLD_BPS;
  if (penalized) return { feeBps: PENALTY_FEE_BPS, feeTier: "penalty" };
  return { feeBps: SELL_FEE_BPS, feeTier: "sell" };
}

function splitBuyFees(usdcIn: bigint): BuyFeeSplit {
  return {
    donationUsdc: (usdcIn * BUY_DONATION_BPS) / BPS,
    marketingUsdc: (usdcIn * BUY_MARKETING_BPS) / BPS,
  };
}

function splitSell(amountIn: bigint, usdcBeforeSkim: bigint, feeBps: bigint): SellFeeSplit {
  if (feeBps === 0n) {
    // Burn still runs for FeeExempt sells.
    return {
      mode: "return-delta",
      donationUsdc: 0n,
      marketingUsdc: 0n,
      burnPxt: (amountIn * SELL_BURN_BPS) / BPS,
      buybackUsdc: 0n,
    };
  }

  const penalty = feeBps === PENALTY_FEE_BPS;
  const burnBps = penalty ? PENALTY_BURN_BPS : SELL_BURN_BPS;
  const donationBps = penalty ? PENALTY_DONATION_BPS : SELL_DONATION_BPS;
  const marketingBps = penalty ? PENALTY_MARKETING_BPS : SELL_MARKETING_BPS;
  const buybackBps = penalty ? PENALTY_BUYBACK_BPS : SELL_BUYBACK_BPS;

  return {
    mode: "return-delta",
    burnPxt: (amountIn * burnBps) / BPS,
    donationUsdc: (usdcBeforeSkim * donationBps) / BPS,
    marketingUsdc: (usdcBeforeSkim * marketingBps) / BPS,
    buybackUsdc: (usdcBeforeSkim * buybackBps) / BPS,
  };
}

/**
 * V4 Quoter always runs the hook. Recover an approximate zero-Phoenix-tax out
 * by reversing the fees the Quoter baked in.
 */
function estimateNoTaxOut(netFromQuoter: bigint, direction: SwapDirection): bigint {
  if (netFromQuoter === 0n) return 0n;

  if (direction === "sell") {
    // Exact-in sell: 1.85% PXT burn, then pessimistic 35.95% USDC skim.
    const afterBurnUsdc = reverseFee(netFromQuoter, PENALTY_USDC_SKIM_BPS);
    return reverseFee(afterBurnUsdc, SELL_BURN_BPS);
  }
  // Buy: 2.7% USDC skimmed from input before the pool swap.
  return reverseFee(netFromQuoter, BUY_FEE_BPS);
}

/**
 * Exact-in quote with spot + gross + fee breakdown + net (V4 Quoter + Phoenix fee model).
 * @param settlement Wallet ERC-20 vs claims. Claim sells always quote penalty
 *        (matches hook orphan path — no attributeSell rebate).
 */
export async function quoteExactIn(
  direction: SwapDirection,
  amountIn: bigint,
  trader: string,
  settlement: SettlementMode = "wallet",
): Promise<SwapQuote> {
  if (amountIn <= 0n) throw new Error("Amount must be positive");
  if (amountIn > 2n ** 128n - 1n) throw new Error("Amount exceeds uint128");

  const key = buildPoolKey();
  const id = poolIdFromKey(key);

  const pxt = new Contract(config.pxt, PXT_ABI, readProvider);
  const hook = new Contract(config.hook, HOOK_ABI, readProvider);
  const view = new Contract(config.stateView, STATE_VIEW_ABI, readProvider);

  const [walletStatus, balance, window, slot0, block, netQ] = await Promise.all([
    pxt.walletStatus(trader) as Promise<number>,
    pxt.balanceOf(trader) as Promise<bigint>,
    hook.sellWindows(trader) as Promise<[bigint, bigint, bigint]>,
    view.getSlot0(id) as Promise<[bigint, number, number, number]>,
    readProvider.getBlock("latest"),
    quoterExactIn(direction, amountIn, trader),
  ]);

  const now = block?.timestamp ?? Math.floor(Date.now() / 1000);
  const spotPrice = musdcPerPxt(slot0[0], key);
  const status = Number(walletStatus);

  let feeBps = 0n;
  let feeTier: FeeTier = "none";
  let buySplit = EMPTY_BUY_SPLIT;
  let sellSplit: SellFeeSplit = EMPTY_SELL;
  const extraPxtCost = 0n;

  const grossOut = estimateNoTaxOut(netQ.amountOut, direction);
  let amountOut = netQ.amountOut;

  if (direction === "buy") {
    feeBps = BUY_FEE_BPS;
    feeTier = "buy";
    buySplit = splitBuyFees(amountIn);
  } else {
    // Claim sells never run attributeSell — hook keeps full penalty USDC skim.
    const claimsForcePenalty = settlement === "claims";
    const preview = claimsForcePenalty
      ? { feeBps: PENALTY_FEE_BPS, feeTier: "penalty" as FeeTier }
      : previewSellFeeBps({
          walletStatus: status,
          amountIn,
          balance,
          windowStart: window[0],
          soldInWindow: window[1],
          balanceAtStart: window[2],
          now,
        });
    feeBps = preview.feeBps;
    feeTier = preview.feeTier;

    const usdcAfterBurn = reverseFee(netQ.amountOut, PENALTY_USDC_SKIM_BPS);
    sellSplit = splitSell(amountIn, usdcAfterBurn, feeBps);

    const fairUsdcSkimBps =
      feeTier === "none" ? 0n : feeTier === "penalty" ? PENALTY_USDC_SKIM_BPS : SELL_USDC_SKIM_BPS;
    amountOut = applyFee(usdcAfterBurn, fairUsdcSkimBps);
  }

  const walletPxtOut = direction === "sell" ? amountIn + extraPxtCost : 0n;

  return {
    direction,
    amountIn,
    walletPxtOut,
    spotPrice,
    grossOut,
    buySplit,
    sellSplit,
    feeBps,
    feeTier,
    amountOut,
    extraPxtCost,
    tokenInSymbol: direction === "buy" ? "mUSDC" : "PXT",
    tokenOutSymbol: direction === "buy" ? "PXT" : "mUSDC",
    gasEstimate: netQ.gasEstimate,
    hookMode: "return-delta",
    exactness: "exactIn",
    specifiedAmount: amountIn,
    legacyFeeUsdc: 0n,
    nowFeeUsdc: 0n,
  };
}

function usdcSkimBps(tier: FeeTier): bigint {
  if (tier === "none") return 0n;
  if (tier === "penalty") return PENALTY_USDC_SKIM_BPS;
  if (tier === "sell") return SELL_USDC_SKIM_BPS;
  return 0n;
}

/**
 * Exact-out quote. Typed `specifiedOut` is PXT for buys, mUSDC for sells.
 * USDC fees use gross-up so published bps apply to total flow (RIFM).
 */
export async function quoteExactOut(
  direction: SwapDirection,
  specifiedOut: bigint,
  trader: string,
  settlement: SettlementMode = "wallet",
): Promise<SwapQuote> {
  if (specifiedOut <= 0n) throw new Error("Amount must be positive");
  if (specifiedOut > 2n ** 128n - 1n) throw new Error("Amount exceeds uint128");

  const key = buildPoolKey();
  const id = poolIdFromKey(key);

  const pxt = new Contract(config.pxt, PXT_ABI, readProvider);
  const hook = new Contract(config.hook, HOOK_ABI, readProvider);
  const view = new Contract(config.stateView, STATE_VIEW_ABI, readProvider);

  const [walletStatus, balance, window, slot0, block, inQ] = await Promise.all([
    pxt.walletStatus(trader) as Promise<number>,
    pxt.balanceOf(trader) as Promise<bigint>,
    hook.sellWindows(trader) as Promise<[bigint, bigint, bigint]>,
    view.getSlot0(id) as Promise<[bigint, number, number, number]>,
    readProvider.getBlock("latest"),
    quoterExactOut(direction, specifiedOut, trader),
  ]);

  const now = block?.timestamp ?? Math.floor(Date.now() / 1000);
  const spotPrice = musdcPerPxt(slot0[0], key);
  const status = Number(walletStatus);
  const extraPxtCost = 0n;
  const amountIn = inQ.amountIn;

  let feeBps = 0n;
  let feeTier: FeeTier = "none";
  let buySplit = EMPTY_BUY_SPLIT;
  let sellSplit: SellFeeSplit = EMPTY_SELL;
  let amountOut = specifiedOut;
  let legacyFeeUsdc = 0n;
  let nowFeeUsdc = 0n;
  let grossOut = specifiedOut;

  if (direction === "buy") {
    feeBps = BUY_FEE_BPS;
    feeTier = "buy";
    buySplit = splitBuyFees(amountIn);
    nowFeeUsdc = buySplit.donationUsdc + buySplit.marketingUsdc;
    const poolUsdc = amountIn > nowFeeUsdc ? amountIn - nowFeeUsdc : 0n;
    legacyFeeUsdc = (poolUsdc * BUY_FEE_BPS) / BPS;
  } else {
    const claimsForcePenalty = settlement === "claims";
    const preview = claimsForcePenalty
      ? { feeBps: PENALTY_FEE_BPS, feeTier: "penalty" as FeeTier }
      : previewSellFeeBps({
          walletStatus: status,
          amountIn,
          balance,
          windowStart: window[0],
          soldInWindow: window[1],
          balanceAtStart: window[2],
          now,
        });
    feeBps = preview.feeBps;
    feeTier = preview.feeTier;

    const fairUsdcBps = usdcSkimBps(feeTier);
    const penGross = specifiedOut + grossUp(specifiedOut, PENALTY_USDC_SKIM_BPS);
    const fairGross = specifiedOut + grossUp(specifiedOut, fairUsdcBps);
    sellSplit = splitSell(amountIn, fairGross, feeBps);

    const penSkim = (penGross * PENALTY_USDC_SKIM_BPS) / BPS;
    nowFeeUsdc =
      sellSplit.donationUsdc + sellSplit.marketingUsdc + sellSplit.buybackUsdc;
    legacyFeeUsdc = (specifiedOut * fairUsdcBps) / BPS;

    const rebate = penSkim > nowFeeUsdc ? penSkim - nowFeeUsdc : 0n;
    amountOut = specifiedOut + rebate;
    grossOut = penGross;
  }

  return {
    direction,
    exactness: "exactOut",
    amountIn,
    specifiedAmount: specifiedOut,
    walletPxtOut: direction === "sell" ? amountIn + extraPxtCost : 0n,
    spotPrice,
    grossOut,
    buySplit,
    sellSplit,
    feeBps,
    feeTier,
    amountOut,
    extraPxtCost,
    legacyFeeUsdc,
    nowFeeUsdc,
    tokenInSymbol: direction === "buy" ? "mUSDC" : "PXT",
    tokenOutSymbol: direction === "buy" ? "PXT" : "mUSDC",
    gasEstimate: inQ.gasEstimate,
    hookMode: "return-delta",
  };
}

export async function quoteSwap(
  direction: SwapDirection,
  amount: bigint,
  trader: string,
  settlement: SettlementMode = "wallet",
  exactness: SwapExactness = "exactIn",
): Promise<SwapQuote> {
  return exactness === "exactOut"
    ? quoteExactOut(direction, amount, trader, settlement)
    : quoteExactIn(direction, amount, trader, settlement);
}

export function feeTierLabel(tier: FeeTier, bps: bigint): string {
  if (tier === "none" || bps === 0n) return "No Phoenix fee";
  if (tier === "buy") return `Buy fee (${Number(bps) / 100}%)`;
  if (tier === "penalty") return `Penalty fee (${Number(bps) / 100}%)`;
  return `Sell fee (${Number(bps) / 100}%)`;
}

// Keep surcharge constant available for shared fee-model tooling.
export { formatSpot, PENALTY_SURCHARGE_BPS };
