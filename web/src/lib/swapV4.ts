import { AbiCoder, Contract, MaxUint256, Wallet, getAddress, type Signer } from "ethers";
import {
  ERC20_ABI,
  MOCK_ERC20_ABI,
  ANTI_BOT_OPEN_SELL_ABI,
  POOL_MANAGER_ABI,
  POOL_SWAP_TEST_ABI,
  config,
} from "../contracts";
import { ANVIL_WALLETS } from "./anvilWallet";
import { readProvider } from "./providers";

/** Uniswap v4 TickMath bounds */
const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

export type SwapDirection = "buy" | "sell";

/** How PoolSwapTest settles / takes the trader's leg. */
export type SettlementMode = "wallet" | "claims";

export type PoolKeyStruct = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

/** ERC-6909 currency id for an address-token (uint160 cast). */
export function currencyClaimId(token: string): bigint {
  return BigInt(getAddress(token));
}

export async function readPxtClaimBalance(owner: string): Promise<bigint> {
  const pm = new Contract(config.poolManager, POOL_MANAGER_ABI, readProvider);
  return (await pm.balanceOf(owner, currencyClaimId(config.pxt))) as bigint;
}

export function buildPoolKey(): PoolKeyStruct {
  const pxt = getAddress(config.pxt);
  const quote = getAddress(config.quote);
  const [currency0, currency1] = pxt.toLowerCase() < quote.toLowerCase() ? [pxt, quote] : [quote, pxt];
  return {
    currency0,
    currency1,
    fee: config.poolFee,
    tickSpacing: config.tickSpacing,
    hooks: getAddress(config.hook),
  };
}

export function zeroForOne(direction: SwapDirection, key: PoolKeyStruct): boolean {
  const quoteIs0 = key.currency0.toLowerCase() === getAddress(config.quote).toLowerCase();
  const pxtIs0 = key.currency0.toLowerCase() === getAddress(config.pxt).toLowerCase();
  if (direction === "buy") return quoteIs0; // quote → pxt
  return pxtIs0; // pxt → quote
}

/** Mint mUSDC to trader if short (uses admin owner of MockERC20). */
export async function ensureQuoteBalance(trader: string, amountIn: bigint): Promise<void> {
  const musdc = new Contract(config.quote, MOCK_ERC20_ABI, readProvider);
  const bal = (await musdc.balanceOf(trader)) as bigint;
  if (bal >= amountIn) return;

  const need = amountIn - bal + amountIn;
  const adminSigner = new Wallet(ANVIL_WALLETS[0].privateKey, readProvider);
  const writable = musdc.connect(adminSigner) as Contract;
  await (await writable.mint(trader, need)).wait();
}

async function ensurePoolSwapOperator(signer: Signer): Promise<void> {
  const trader = await signer.getAddress();
  const pm = new Contract(config.poolManager, POOL_MANAGER_ABI, signer);
  const ok = (await pm.isOperator(trader, config.poolSwapTest)) as boolean;
  if (ok) return;
  await (await pm.setOperator(config.poolSwapTest, true)).wait();
}

/**
 * Exact-in swap via PoolSwapTest.
 * - wallet: ERC-20 take/settle (default)
 * - claims: buy mints PXT claims; sell burns PXT claims (skips Pxt ERC-20 dump / attributeSell)
 */
export async function swapExactIn(
  signer: Signer,
  direction: SwapDirection,
  amountIn: bigint,
  settlement: SettlementMode = "wallet",
): Promise<string> {
  const trader = await signer.getAddress();
  const key = buildPoolKey();
  const zfo = zeroForOne(direction, key);
  const useClaims = settlement === "claims";

  if (direction === "buy") {
    await ensureQuoteBalance(trader, amountIn);
    const musdc = new Contract(config.quote, ERC20_ABI, signer);
    const allowance = (await musdc.allowance(trader, config.poolSwapTest)) as bigint;
    if (allowance < amountIn) {
      await (await musdc.approve(config.poolSwapTest, MaxUint256)).wait();
    }
  } else if (useClaims) {
    const claims = await readPxtClaimBalance(trader);
    if (claims < amountIn) {
      throw new Error(
        `Not enough PXT claims: need ${amountIn.toString()}, have ${claims.toString()}. Buy with “Receive as claims” first.`,
      );
    }
    await ensurePoolSwapOperator(signer);
  } else {
    const pxt = new Contract(config.pxt, ERC20_ABI, signer);
    const allowance = (await pxt.allowance(trader, config.poolSwapTest)) as bigint;
    if (allowance < amountIn) {
      await (await pxt.approve(config.poolSwapTest, MaxUint256)).wait();
    }
  }

  const swapTest = new Contract(config.poolSwapTest, POOL_SWAP_TEST_ABI, signer);
  const hookData = AbiCoder.defaultAbiCoder().encode(["address"], [trader]);
  const tx = await swapTest.swap(
    key,
    {
      zeroForOne: zfo,
      amountSpecified: -amountIn,
      sqrtPriceLimitX96: zfo ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n,
    },
    {
      takeClaims: useClaims && direction === "buy",
      settleUsingBurn: useClaims && direction === "sell",
    },
    hookData,
  );
  const receipt = await tx.wait();
  return receipt.hash as string;
}

/**
 * Atomic anti-bot ceremony: clearSellProtection + exact-in ERC-20 sell in one tx.
 * Caller must be `PhoenixAntiBotOpenSell.operator()`. On-chain `antiBotSeller` is the
 * helper contract itself (no tx.origin).
 */
export async function openTradingWithFirstSell(signer: Signer, amountIn: bigint): Promise<string> {
  const openSellAddr = config.antiBotOpenSell;
  if (!openSellAddr || openSellAddr === "undefined") {
    throw new Error("VITE_ANTI_BOT_OPEN_SELL missing — re-run make bootstrap-anvil");
  }
  const trader = await signer.getAddress();
  const openSell = new Contract(openSellAddr, ANTI_BOT_OPEN_SELL_ABI, signer);
  const operator = (await openSell.operator()) as string;
  if (trader.toLowerCase() !== operator.toLowerCase()) {
    throw new Error(`Connect as openSell operator (${operator}) — usually Admin`);
  }
  const key = buildPoolKey();
  const pxt = new Contract(config.pxt, ERC20_ABI, signer);
  const allowance = (await pxt.allowance(trader, openSellAddr)) as bigint;
  if (allowance < amountIn) {
    await (await pxt.approve(openSellAddr, MaxUint256)).wait();
  }
  const tx = await openSell.openWithExactInSell(key, amountIn, "0x");
  const receipt = await tx.wait();
  return receipt.hash as string;
}

export async function transferPxt(signer: Signer, to: string, amount: bigint): Promise<string> {
  const pxt = new Contract(config.pxt, ERC20_ABI, signer);
  const tx = await pxt.transfer(to, amount);
  const receipt = await tx.wait();
  return receipt.hash as string;
}
