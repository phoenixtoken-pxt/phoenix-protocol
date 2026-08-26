import { getAddress } from "ethers";

/** Normalize env addresses (accepts any casing; rejects invalid hex). */
function addr(value: string | undefined, fallback = ""): string {
  const raw = (value && value !== "undefined" ? value : fallback).trim();
  if (!raw) return "";
  return getAddress(raw.toLowerCase());
}

export const config = {
  chainId: Number(import.meta.env.VITE_CHAIN_ID ?? "84532"),
  rpcUrl: import.meta.env.VITE_RPC_URL ?? "http://127.0.0.1:8545",
  pxt: addr(import.meta.env.VITE_PXT_ADDRESS as string),
  quote: addr(import.meta.env.VITE_QUOTE_TOKEN_ADDRESS as string),
  hook: addr(
    (import.meta.env.VITE_PHOENIX_HOOK || import.meta.env.VITE_PHOENIX_V4_HOOK) as string,
  ),
  feeCollector: addr(import.meta.env.VITE_FEE_COLLECTOR as string),
  antiBotOpenSell: addr(import.meta.env.VITE_ANTI_BOT_OPEN_SELL as string),
  poolManager: addr(
    import.meta.env.VITE_POOL_MANAGER as string,
    "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
  ),
  poolSwapTest: addr(
    import.meta.env.VITE_POOL_SWAP_TEST as string,
    "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9",
  ),
  poolModifyLiquidityTest: addr(
    import.meta.env.VITE_POOL_MODIFY_LIQUIDITY_TEST as string,
    "0x37429cD17Cb1454C34E7F50b09725202Fd533039",
  ),
  stateView: addr(
    import.meta.env.VITE_STATE_VIEW as string,
    "0x571291b572ed32ce6751a2Cb2486EbEe8DEfB9B4",
  ),
  quoter: addr(
    import.meta.env.VITE_QUOTER as string,
    "0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa",
  ),
  donation: addr(import.meta.env.VITE_DONATION_WALLET as string),
  marketing: addr(import.meta.env.VITE_MARKETING_WALLET as string),
  hookMode: "return-delta" as const,
  // Pool fee is 0 for the return-delta hook
  poolFee: Number(import.meta.env.VITE_POOL_FEE ?? "0"),
  tickSpacing: 60,
  /** Otterscan base URL (`make explorer`). */
  explorerUrl: (import.meta.env.VITE_EXPLORER_URL as string) || "http://127.0.0.1:5100",
};

export function explorerTxUrl(txHash: string): string {
  const base = config.explorerUrl.replace(/\/$/, "");
  return `${base}/tx/${txHash}`;
}

const REQUIRED = ["pxt", "quote", "hook", "donation", "marketing"] as const;

export function assertConfig() {
  const missing: string[] = REQUIRED.filter((k) => {
    const v = config[k];
    return !v || v === "undefined";
  });
  if (!config.feeCollector || config.feeCollector === "undefined") {
    missing.push("feeCollector");
  }
  if (missing.length > 0) {
    throw new Error(
      `Missing web config: ${missing.join(", ")}. Run make bootstrap-anvil first.`,
    );
  }
}

export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
] as const;

export const MOCK_ERC20_ABI = [...ERC20_ABI, "function mint(address to, uint256 amount)"] as const;

export const PXT_ABI = [
  ...ERC20_ABI,
  "function sellUnlockTimestamp() view returns (uint256)",
  "function owner() view returns (address)",
  "function walletStatus(address) view returns (uint8)",
  "function poolManager() view returns (address)",
  "function antiBotSeller() view returns (address)",
  "function sellProtectionCleared() view returns (bool)",
  "function clearSellProtection()",
] as const;

export const ANTI_BOT_OPEN_SELL_ABI = [
  "function openWithExactInSell((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key, uint256 amountIn, bytes hookData) returns (int256 delta)",
  "function pxt() view returns (address)",
  "function operator() view returns (address)",
] as const;

export const HOOK_ABI = [
  "function antiBotSeller() view returns (address)",
  "function sellProtectionCleared() view returns (bool)",
  "function pxt() view returns (address)",
  "function feeCollector() view returns (address)",
  // Dump window lives on the hook.
  "function sellWindows(address) view returns (uint64 windowStart, uint256 soldInWindow, uint256 balanceAtWindowStart)",
  "function orphanSkim() view returns (uint128 pxtIn, uint128 usdcOut, uint128 usdcSkim, address quote)",
  "function finalizeOrphanedSell()",
  "event HookFeeCharged(address indexed trader, uint8 kind, uint256 feeBps, uint256 feeAmount)",
  "event SellProtectionCleared()",
] as const;

export const FEE_COLLECTOR_ABI = [
  "function collect()",
  "function executeBuyback(uint256 usdcAmount, uint256 minPxtBought, uint256 deadline) returns (uint256 usdcSpent, uint256 pxtBought)",
  "function isAuthorizedBuybackCaller(address caller) view returns (bool)",
  "function maxBuybackSlippageBps() view returns (uint16)",
  "function frozenSqrtPriceX96() view returns (uint160)",
  "function pendingSqrtPriceX96() view returns (uint160)",
  "function pendingSpotBlock() view returns (uint256)",
  "function quoteBuyback() view returns (uint256 usdcSpendable, uint128 positionLiquidity)",
  "function pending(address token) view returns (uint256 donation, uint256 marketing, uint256 burnAmount, uint256 buyback)",
  "function seedLiquidityAdded() view returns (bool)",
  "function recyclePxt() view returns (uint256)",
  "function lastRecycleTickLower() view returns (int24)",
  "function lastRecycleTickUpper() view returns (int24)",
  "function lastRecycleLiquidity() view returns (uint128)",
  "function recycleWidthSpacings() view returns (uint24)",
  "function donationWallet() view returns (address)",
  "function marketingWallet() view returns (address)",
  "event FeesCollected(address indexed caller, address indexed token, uint256 donation, uint256 marketing, uint256 burnAmount, uint256 buyback, uint256 pulledFromPool)",
  "event FeeAccrued(address indexed token, uint8 kind, uint256 grossAmount, uint256 donation, uint256 marketing, uint256 burnAmount, uint256 buyback)",
  "event TokensBurned(address indexed token, uint256 amount)",
  "event BuybackExecuted(address indexed caller, uint256 usdcSpent, uint256 pxtBought, uint256 recycleAdded, int24 recycleTickLower, int24 recycleTickUpper, uint128 recycleLiquidity)",
] as const;

export const POOL_MANAGER_ABI = [
  "function balanceOf(address owner, uint256 id) view returns (uint256)",
  "function isOperator(address owner, address operator) view returns (bool)",
  "function setOperator(address operator, bool approved) returns (bool)",
] as const;

export const POOL_SWAP_TEST_ABI = [
  "function swap((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key, (bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96) params, (bool takeClaims,bool settleUsingBurn) testSettings, bytes hookData) payable returns (int256 delta)",
] as const;

export const STATE_VIEW_ABI = [
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function getLiquidity(bytes32 poolId) view returns (uint128 liquidity)",
  "function getFeeGrowthGlobals(bytes32 poolId) view returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1)",
  "function getFeeGrowthInside(bytes32 poolId, int24 tickLower, int24 tickUpper) view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)",
  "function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt) view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128)",
] as const;
