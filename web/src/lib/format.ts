import { formatUnits, parseUnits } from "ethers";

export function formatBal(value: bigint, decimals = 6): string {
  const raw = formatUnits(value, decimals);
  const n = Number(raw);
  if (!Number.isFinite(n) || n === 0) return "0";
  if (Math.abs(n) < 0.000001) return n.toExponential(4);
  return n.toLocaleString(undefined, { maximumFractionDigits: 6 });
}

export function parseAmount(input: string, decimals = 6): bigint {
  const trimmed = input.trim();
  if (!trimmed) throw new Error("Enter an amount");
  return parseUnits(trimmed, decimals);
}

export function shortAddr(addr: string): string {
  if (!addr || addr.length < 10) return addr || "—";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function formatUnix(ts: number | bigint): string {
  const n = Number(ts);
  if (!n) return "—";
  return new Date(n * 1000).toISOString().replace(".000Z", "Z");
}
