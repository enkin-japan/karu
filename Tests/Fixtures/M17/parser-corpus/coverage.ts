// Coverage of TypeScript syntax for the hand-written prototype (valid code).
import def, { a as b, type C } from "./mod";
import * as ns from "ns";
import type { T1 } from "./types";
import "side-effect";
import fs = require("fs");
export * from "./all";
export * as grouped from "./grouped";
export { b as renamed, def };
export type { T1 };

declare module "virtual" {
  export const value: number;
}
declare global {
  interface Window { app: unknown }
}
namespace Outer.Inner {
  export const k = 1;
}

type Fn<T, R = void> = (arg: T, ...rest: unknown[]) => R;
type Ctor = new (...args: any[]) => object;
type Cond<T> = T extends string ? "s" : T extends number ? "n" : never;
type Mapped<T> = { readonly [K in keyof T as `get${Capitalize<string & K>}`]-?: () => T[K] };
type Tup = [name: string, age?: number, ...rest: boolean[]];
type Inferred<T> = T extends Promise<infer U> ? U : T;
type Lit = "a" | "b" | 1 | -1 | true | null | undefined;
type Q = typeof ns.value;
type Idx = Lit[number] | keyof typeof def;
type Obj = { a: number; b?: string; [key: string]: unknown; method(x: number): void; new (x: string): Obj; (y: number): string };

const enum Flags { None = 0, A = 1 << 0, B = 1 << 1, AB = A | B }
enum Colors { Red = "red", Green = "green" }

interface Shape<T extends object = {}> extends Base, Other<T> {
  readonly kind: string;
  area?(): number;
  get size(): number;
}

export abstract class Animal<T> implements Shape<T> {
  #secret = 1;
  static count = 0;
  private readonly name: string;
  protected legs?: number;
  declare kind: string;
  [key: string]: unknown;
  static { Animal.count = 0; }

  constructor(name: string, public age = 0) {
    super();
    this.name = name;
  }

  get size(): number { return this.#secret; }
  set size(v: number) { this.#secret = v; }
  abstract speak(): string;
  async *walk(steps: number): AsyncGenerator<number> {
    for await (const s of source()) yield s;
  }
  protected override toString(): string { return `${this.name}:${this.age}`; }
}

function overload(x: string): string;
function overload(x: number): number;
function overload(x: any) { return x; }

export function isString(x: unknown): x is string { return typeof x === "string"; }
function assertDefined<T>(v: T | undefined): asserts v is T {}

@decorator()
class Decorated {
  @field() prop = 1;
  method(@inject() dep: Dep) {}
}

let { a: aa = 1, b: { c: cc }, ...others } = obj;
let [first, , third = 3, ...tail] = arr;
var legacy;
const tuple = [1, "x"] as const;
const conf = { port: 80 } satisfies Config;
const re = /ab+c/gi.test(input) ? input!.trim() : input?.toLowerCase?.() ?? "";
const tagged = String.raw`line ${value} end`;
const nested = `outer ${`inner ${deep}`} done`;
const big = 1_000n + 0x1f + 1e-3 + .5;
const generic = identity<string>("x");
const instance = new Map<string, number[]>([["a", [1]]]);
const arrowGeneric = <T,>(v: T): T => v;
const asyncArrow = async ({ id }: { id: number }) => await fetch(`/u/${id}`);
const fnExpr = function named(this: Window, a: number) { return a; };
const objLit = { a, b: 2, [computed]: 3, ...spread, method() {}, get g() { return 1; }, set s(v) {}, async am() {}, *gen() {} };
let assign: number;
assign = assign! + 1;
assign ||= 2; assign &&= 3; assign ??= 4; assign **= 2; assign >>>= 1; assign >>= 1;
const shifted = (assign >> 1) >>> 2 << 3;
const cmp = assign < 3 && assign > 1 && assign >= 0 && assign <= 9;
label: for (let i = 0, j = 10; i < j; i++, j--) {
  if (i in obj) continue label;
  else if (!(i instanceof Number)) break label;
}
for (const key in obj) delete obj[key];
do { assign--; } while (assign > 0);
switch (assign) {
  case 1:
  case 2: { void 0; break; }
  default:
    throw new Error("x");
}
try { risky(); } catch { recover(); } finally { done(); }
try { risky(); } catch (e: unknown) { console.error(e); }
const dyn = await import("./dyn");
const meta = import.meta.url;
debugger;
export default class {}
