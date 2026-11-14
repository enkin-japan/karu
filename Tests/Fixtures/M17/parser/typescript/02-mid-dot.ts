import { readFileSync } from "node:fs";

type Json = Record<string, unknown>;

export function loadJson(path: string): Json {
  const raw = readFileSync(path, "utf8");
  const parsed = JSON.parse(raw).‸
  return parsed as Json;
}

export function dumpJson(value: Json, indent = 2): string {
  return JSON.stringify(value, null, indent);
}

const EMPTY: Json = {};
