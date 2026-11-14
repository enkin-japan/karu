// Work in progress: await paren receiver
// Notes: this module is still being drafted;
import { load, save } from "./store";

export interface Snapshot { key: string; rows: number[] }

export async function refresh(key: string): Promise<Snapshot> {
  const fresh = (await load()).‸
  await save(key, fresh);
  return { key, rows: [] };
}

export async function clear(key: string) {
  await save(key, []);
}
