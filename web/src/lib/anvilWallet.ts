import { Wallet, getAddress, type Signer } from "ethers";
import { readProvider } from "./providers";

/** Default Anvil mnemonic accounts — local testing only. #4 (Shares / RECIPIENT_APPROVER) omitted from the UI picker. */
export const ANVIL_WALLETS = [
  {
    label: "Admin",
    address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    privateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    note: "FeeExempt · anti-bot first seller",
  },
  {
    label: "Buyback",
    address: "0x71bE63f3384f5fb98995898A86B02Fb2426c5788",
    privateKey: "0x701b615bbdfb9de65240bc28bd21bbc0d996645a3dd57e7b12bc2bdf6f192c82",
    note: "executeBuyback keeper (Anvil #11)",
  },
  {
    label: "Donations",
    address: "0x70997970c51812Dc3a010C7d01b50b0d17Ef88c8",
    privateKey: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    note: "Fee wallet",
  },
  {
    label: "Marketing",
    address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    privateKey: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    note: "Fee wallet",
  },
  {
    label: "NoPenalty",
    address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    privateKey: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
    note: "Always 5.4% sell · no dump window",
  },
  {
    label: "Tester #5",
    address: "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
    privateKey: "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
    note: "Best for taxed buys/sells",
  },
  {
    label: "Tester #6",
    address: "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
    privateKey: "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
    note: "",
  },
  {
    label: "Tester #7",
    address: "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955",
    privateKey: "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
    note: "",
  },
  {
    label: "Tester #8",
    address: "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
    privateKey: "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
    note: "",
  },
  {
    label: "Tester #9",
    address: "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
    privateKey: "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
    note: "",
  },
] as const;

/** Admin, Buyback, Donations, Marketing, NoPenalty — first wallet-grid row. */
export const ANVIL_OPS_COUNT = 5;
/** Tester #5 — default dump-tier trader (not the buyback keeper). */
export const ANVIL_DEFAULT_TRADER_INDEX = 5 as const;

export type AnvilWalletIndex = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9;

/** Clear forked EIP-7702 bytecode so transfers treat the account as a plain EOA. */
export async function resetEoaIfNeeded(address: string): Promise<void> {
  const checksummed = getAddress(address);
  const code = await readProvider.getCode(checksummed);
  if (code !== "0x") {
    await readProvider.send("anvil_setCode", [checksummed, "0x"]);
  }
}

export async function connectAnvilWallet(index: AnvilWalletIndex): Promise<{
  signer: Signer;
  account: string;
  label: string;
}> {
  const wallet = ANVIL_WALLETS[index];
  await resetEoaIfNeeded(wallet.address);
  const signer = new Wallet(wallet.privateKey, readProvider);
  const account = await signer.getAddress();
  return { signer, account, label: wallet.label };
}
