import { Contract } from "ethers";
import { useCallback, useEffect, useState } from "react";
import { ERC20_ABI, STATE_VIEW_ABI, config } from "../contracts";
import { readProvider } from "../lib/providers";
import { musdcPerPxt, poolIdFromKey } from "../lib/spotPrice";
import { buildPoolKey } from "../lib/swapV4";

export type PricePoint = {
  /** Unix ms (chain timestamp × 1000) */
  t: number;
  price: number;
};

export type SpotSnapshot = {
  price: number;
  tick: number;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  /** PXT held by PoolManager (this pool's reserves on a fresh deploy). */
  pxtReserve: bigint;
  /** mUSDC held by PoolManager. */
  musdcReserve: bigint;
};

const MAX_POINTS = 3600;
const POLL_MS = 1500;

export function useSpotPrice(enabled: boolean) {
  const [spot, setSpot] = useState<SpotSnapshot | null>(null);
  const [history, setHistory] = useState<PricePoint[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!enabled || !config.pxt || !config.hook) {
      setLoading(false);
      return;
    }
    try {
      const key = buildPoolKey();
      const id = poolIdFromKey(key);
      const view = new Contract(config.stateView, STATE_VIEW_ABI, readProvider);
      const pxt = new Contract(config.pxt, ERC20_ABI, readProvider);
      const musdc = new Contract(config.quote, ERC20_ABI, readProvider);
      const [slot0, liquidity, pxtReserve, musdcReserve, block] = await Promise.all([
        view.getSlot0(id) as Promise<[bigint, number, number, number]>,
        view.getLiquidity(id) as Promise<bigint>,
        pxt.balanceOf(config.poolManager) as Promise<bigint>,
        musdc.balanceOf(config.poolManager) as Promise<bigint>,
        readProvider.getBlock("latest"),
      ]);
      const sqrtPriceX96 = slot0[0];
      const tick = Number(slot0[1]);
      const price = musdcPerPxt(sqrtPriceX96, key);
      const chainSec = block?.timestamp ?? Math.floor(Date.now() / 1000);

      setSpot({ price, tick, sqrtPriceX96, liquidity, pxtReserve, musdcReserve });
      setError(null);
      setHistory((prev) => {
        const point = { t: chainSec * 1000, price };
        const next = [...prev, point];
        // Drop duplicate consecutive timestamps (same block)
        if (prev.length && prev[prev.length - 1].t === point.t) {
          return [...prev.slice(0, -1), point].slice(-MAX_POINTS);
        }
        return next.slice(-MAX_POINTS);
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [enabled]);

  useEffect(() => {
    if (!enabled) return;
    void refresh();
    const id = window.setInterval(() => void refresh(), POLL_MS);
    return () => window.clearInterval(id);
  }, [enabled, refresh]);

  return { spot, history, loading, error, refresh };
}
