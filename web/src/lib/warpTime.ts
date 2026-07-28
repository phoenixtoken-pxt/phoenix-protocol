import { readProvider } from "./providers";

export async function readChainTimestamp(): Promise<number> {
  const block = await readProvider.getBlock("latest");
  if (!block) throw new Error("Could not read latest block");
  return block.timestamp;
}

export async function warpToTimestamp(target: number): Promise<number> {
  const now = await readChainTimestamp();
  if (target > now) {
    await readProvider.send("anvil_setNextBlockTimestamp", [target]);
  }
  await readProvider.send("evm_mine", []);
  return readChainTimestamp();
}

export async function warpBySeconds(delta: number): Promise<number> {
  const now = await readChainTimestamp();
  return warpToTimestamp(now + delta);
}

export async function warpToSellUnlock(sellUnlock: bigint): Promise<number> {
  return warpToTimestamp(Number(sellUnlock));
}
