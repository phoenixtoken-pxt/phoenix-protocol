import { Contract, getAddress } from "ethers";
import { STATE_VIEW_ABI, config } from "../contracts";
import { readProvider } from "./providers";
import { poolIdFromKey } from "./spotPrice";
import { buildPoolKey } from "./swapV4";

const Q128 = 1n << 128n;

/** Bootstrap fork LP range (matches BootstrapReturnDeltaFork.s.sol). */
export const LP_TICK_LOWER = Number(import.meta.env.VITE_LP_TICK_LOWER ?? "-887220");
export const LP_TICK_UPPER = Number(import.meta.env.VITE_LP_TICK_UPPER ?? "887220");

export type LpFeeSnapshot = {
  /** Last swap's dynamic LP fee in Uniswap units (1e6 = 100%). */
  lpFeeUnits: number;
  /** Human % e.g. 2.7 */
  lpFeePercent: number;
  positionLiquidity: bigint;
  /** Uncollected fees owed to the seeded LP position. */
  fees0: bigint;
  fees1: bigint;
  /** Mapped to token symbols for the UI. */
  feesPxt: bigint;
  feesMusdc: bigint;
  tickLower: number;
  tickUpper: number;
  positionOwner: string;
};

function tokensOwed(feeGrowthInside: bigint, feeGrowthLast: bigint, liquidity: bigint): bigint {
  if (liquidity === 0n || feeGrowthInside <= feeGrowthLast) return 0n;
  return ((feeGrowthInside - feeGrowthLast) * liquidity) / Q128;
}

/** Uniswap fee units (1e6 = 100%) → percent number. */
export function lpFeeUnitsToPercent(units: number): number {
  return units / 10_000;
}

/**
 * Read current dynamic LP fee + uncollected fees on the Anvil bootstrap position
 * (owned by PoolModifyLiquidityTest, salt 0, ticks ±60_000).
 */
export async function readLpFees(): Promise<LpFeeSnapshot> {
  const key = buildPoolKey();
  const id = poolIdFromKey(key);
  const owner = getAddress(config.feeCollector || config.poolModifyLiquidityTest);
  const view = new Contract(config.stateView, STATE_VIEW_ABI, readProvider);

  const [slot0, pos, growthInside] = await Promise.all([
    view.getSlot0(id) as Promise<[bigint, number, number, number]>,
    view.getPositionInfo(id, owner, LP_TICK_LOWER, LP_TICK_UPPER, "0x" + "00".repeat(32)) as Promise<
      [bigint, bigint, bigint]
    >,
    view.getFeeGrowthInside(id, LP_TICK_LOWER, LP_TICK_UPPER) as Promise<[bigint, bigint]>,
  ]);

  const lpFeeUnits = Number(slot0[3]);
  const [liquidity, last0, last1] = pos;
  const [inside0, inside1] = growthInside;
  const fees0 = tokensOwed(inside0, last0, liquidity);
  const fees1 = tokensOwed(inside1, last1, liquidity);

  const pxtIs0 = key.currency0.toLowerCase() === getAddress(config.pxt).toLowerCase();
  return {
    lpFeeUnits,
    lpFeePercent: lpFeeUnitsToPercent(lpFeeUnits),
    positionLiquidity: liquidity,
    fees0,
    fees1,
    feesPxt: pxtIs0 ? fees0 : fees1,
    feesMusdc: pxtIs0 ? fees1 : fees0,
    tickLower: LP_TICK_LOWER,
    tickUpper: LP_TICK_UPPER,
    positionOwner: owner,
  };
}
