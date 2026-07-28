import { JsonRpcProvider } from "ethers";
import { config } from "../contracts";

export const readProvider = new JsonRpcProvider(config.rpcUrl, config.chainId, {
  staticNetwork: true,
});

export async function assertLocalDeploy() {
  const code = await readProvider.getCode(config.pxt);
  if (code === "0x") {
    throw new Error(
      "PXT not found on local Anvil. Start make anvil-base-sepolia-fork and run make bootstrap-anvil.",
    );
  }
}
