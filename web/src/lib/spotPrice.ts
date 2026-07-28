import { AbiCoder, keccak256, getAddress } from "ethers";
import { config } from "../contracts";
import { buildPoolKey, type PoolKeyStruct } from "./swapV4";

/** Matches Uniswap v4 `PoolIdLibrary.toId` (keccak256 of 5×32-byte memory layout). */
export function poolIdFromKey(key: PoolKeyStruct): string {
  return keccak256(
    AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint24", "int24", "address"],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

/** currency1 / currency0 in raw token units from sqrtPriceX96. */
export function currency1PerCurrency0(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 === 0n) return 0;
  // (sqrtP^2 / 2^192) with 1e18 fixed-point intermediate for JS Number
  const scaled = (sqrtPriceX96 * sqrtPriceX96 * 10n ** 18n) / 2n ** 192n;
  return Number(scaled) / 1e18;
}

/**
 * Spot as mUSDC per 1 PXT (both 6 decimals → raw ratio == human ratio).
 */
export function musdcPerPxt(sqrtPriceX96: bigint, key: PoolKeyStruct = buildPoolKey()): number {
  const p1per0 = currency1PerCurrency0(sqrtPriceX96);
  if (p1per0 === 0) return 0;
  const pxtIs0 = key.currency0.toLowerCase() === getAddress(config.pxt).toLowerCase();
  return pxtIs0 ? p1per0 : 1 / p1per0;
}

export function formatSpot(price: number | null): string {
  if (price === null || !Number.isFinite(price)) return "—";
  if (price >= 100) return price.toFixed(4);
  if (price >= 1) return price.toFixed(6);
  return price.toFixed(8);
}
