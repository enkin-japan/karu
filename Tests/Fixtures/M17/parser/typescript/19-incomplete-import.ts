// Work in progress: incomplete import
// Notes: this module is still being drafted;
import { readFile, wri‸ } from "node:fs/promises";
import { join } from
import type { Config } from "./config"

export async function readText(dir: string, name: string) {
  return readFile(join(dir, name), "utf8");
}

export const ENCODING = "utf8";

export function sizeOf(text: string) {
  return text.length;
}
