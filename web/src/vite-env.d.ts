/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_CHAIN_ID: string;
  readonly VITE_RPC_URL: string;
  readonly VITE_PXT_ADDRESS: string;
  readonly VITE_QUOTE_TOKEN_ADDRESS: string;
  readonly VITE_PHOENIX_HOOK: string;
  readonly VITE_HOOK_MODE?: string;
  readonly VITE_FEE_COLLECTOR: string;
  readonly VITE_POOL_MANAGER: string;
  readonly VITE_POOL_SWAP_TEST: string;
  readonly VITE_POOL_MODIFY_LIQUIDITY_TEST: string;
  readonly VITE_STATE_VIEW: string;
  readonly VITE_QUOTER: string;
  readonly VITE_DONATION_WALLET: string;
  readonly VITE_MARKETING_WALLET: string;
  readonly VITE_POOL_FEE: string;
  readonly VITE_LP_TICK_LOWER: string;
  readonly VITE_LP_TICK_UPPER: string;
  readonly VITE_EXPLORER_URL: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
