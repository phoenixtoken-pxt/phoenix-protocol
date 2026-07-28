import {
  AreaSeries,
  ColorType,
  CrosshairMode,
  createChart,
  type IChartApi,
  type ISeriesApi,
  type UTCTimestamp,
} from "lightweight-charts";
import { useEffect, useRef } from "react";
import type { PricePoint } from "../hooks/useSpotPrice";
import { formatBal } from "../lib/format";
import { formatSpot } from "../lib/spotPrice";

type Props = {
  history: PricePoint[];
  price: number | null;
  tick: number | null;
  loading: boolean;
  error: string | null;
  pxtReserve?: bigint | null;
  musdcReserve?: bigint | null;
  liquidity?: bigint | null;
};

const HEIGHT = 280;

export function PriceChart({
  history,
  price,
  tick,
  loading,
  error,
  pxtReserve = null,
  musdcReserve = null,
  liquidity = null,
}: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);
  const seriesRef = useRef<ISeriesApi<"Area"> | null>(null);

  useEffect(() => {
    const el = hostRef.current;
    if (!el) return;

    const chart = createChart(el, {
      height: HEIGHT,
      layout: {
        background: { type: ColorType.Solid, color: "transparent" },
        textColor: "#8a9688",
        fontFamily: '"IBM Plex Mono", ui-monospace, monospace',
      },
      grid: {
        vertLines: { color: "#2c352e" },
        horzLines: { color: "#2c352e" },
      },
      rightPriceScale: {
        borderColor: "#2c352e",
        scaleMargins: { top: 0.1, bottom: 0.12 },
      },
      timeScale: {
        borderColor: "#2c352e",
        timeVisible: true,
        secondsVisible: true,
      },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { color: "rgba(232,165,75,0.35)", labelBackgroundColor: "#1f2620" },
        horzLine: { color: "rgba(232,165,75,0.35)", labelBackgroundColor: "#1f2620" },
      },
      handleScroll: { mouseWheel: true, pressedMouseMove: true },
      handleScale: { mouseWheel: true, pinch: true },
    });

    const series = chart.addSeries(AreaSeries, {
      lineColor: "#e8a54b",
      topColor: "rgba(232,165,75,0.35)",
      bottomColor: "rgba(232,165,75,0.02)",
      lineWidth: 2,
      priceFormat: { type: "price", precision: 8, minMove: 0.00000001 },
    });

    chartRef.current = chart;
    seriesRef.current = series;

    const ro = new ResizeObserver(() => {
      if (!hostRef.current) return;
      chart.applyOptions({ width: hostRef.current.clientWidth });
    });
    ro.observe(el);
    chart.applyOptions({ width: el.clientWidth });

    return () => {
      ro.disconnect();
      chart.remove();
      chartRef.current = null;
      seriesRef.current = null;
    };
  }, []);

  useEffect(() => {
    const series = seriesRef.current;
    const chart = chartRef.current;
    if (!series || !chart) return;

    const data = history
      .filter((p) => Number.isFinite(p.price) && p.price > 0)
      .map((p) => ({
        time: Math.floor(p.t / 1000) as UTCTimestamp,
        value: p.price,
      }));

    // lightweight-charts requires unique ascending times
    const deduped: typeof data = [];
    for (const point of data) {
      const last = deduped[deduped.length - 1];
      if (last && last.time === point.time) {
        last.value = point.value;
      } else {
        deduped.push({ ...point });
      }
    }

    series.setData(deduped);
    if (deduped.length > 1) {
      chart.timeScale().scrollToRealTime();
    }
  }, [history]);

  return (
    <section className="panel chart-panel">
      <div className="chart-head">
        <div>
          <h2>Spot price</h2>
          <p className="hint">mUSDC per 1 PXT · polled from Uniswap v4 StateView</p>
        </div>
        <div className="chart-spot">
          <div className="chart-price">{loading && price === null ? "..." : formatSpot(price)}</div>
          <div className="hint">tick {tick ?? "-"} · {history.length} samples</div>
        </div>
      </div>

      <div className="pool-lp">
        <div className="bal">
          <div className="label">Pool PXT</div>
          <div className="value">
            {pxtReserve == null ? "..." : formatBal(pxtReserve)}
          </div>
        </div>
        <div className="bal">
          <div className="label">Pool mUSDC</div>
          <div className="value">
            {musdcReserve == null ? "..." : formatBal(musdcReserve)}
          </div>
        </div>
        <div className="bal">
          <div className="label">Active L</div>
          <div className="value mono-sm">
            {liquidity == null ? "..." : formatLiquidity(liquidity)}
          </div>
        </div>
      </div>

      {error ? <p className="status error">{error}</p> : null}
      <div ref={hostRef} className="chart-host" />
    </section>
  );
}

function formatLiquidity(l: bigint): string {
  if (l === 0n) return "0";
  const s = l.toString();
  if (s.length <= 6) return s;
  const suffixes = ["", "K", "M", "B", "T", "Q"];
  const exp = Math.min(Math.floor((s.length - 1) / 3), suffixes.length - 1);
  const cut = exp * 3;
  const head = s.slice(0, s.length - cut);
  const frac = s.slice(s.length - cut, s.length - cut + 2);
  return frac && Number(frac) > 0 ? `${head}.${frac}${suffixes[exp]}` : `${head}${suffixes[exp]}`;
}
