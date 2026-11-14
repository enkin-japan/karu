// T17.11a grammar coverage (valid TypeScript): destructuring assignment,
// type-only imports / exports, decorators, async / generators.
import type { Config, Options as Opts } from "./config";
import type Default from "./default";
import type * as Types from "./types";
import { type Reader, Writer, type default as Fallback } from "./io";
import json from "./data.json" with { type: "json" };
import fs = require("fs");
export type { Config };
export type * from "./types";
export type * as Ns from "./types";
export { type Reader, Writer as W };

let a: number, b: number, rest: number[];
[a, b] = [b, a];
[a, , b = 2, ...rest] = [1, 2, 3, 4];
({ a, b = 3, c: { d: b }, ...rest } = source());
for ([a, b] of pairs()) {}
for ({ a } of objects()) {}
const { x, y: [z, ...more] = [], ...others } = point();

function sealed(constructor: Function) {}
function log(target: any, key: string, descriptor?: PropertyDescriptor): any {}
function inject(token: string) {
    return (target: object, key: string | undefined, index: number) => {};
}

@sealed
@log
export class Repository<T extends Entity> implements Iterable<T> {
    @log accessor count = 0;
    @log static readonly instances = new Map<string, Repository<any>>();
    #items: T[] = [];
    declare readonly kind: string;

    constructor(@inject("store") private readonly store: Map<string, T>, public name?: string) {}

    @log
    async *stream(this: Repository<T>, limit = 10): AsyncGenerator<T, void, undefined> {
        for await (const item of this.source()) {
            yield item;
            yield* this.#items;
        }
    }

    *[Symbol.iterator](): Iterator<T> {
        yield* this.#items;
    }

    get size(): number { return this.#items.length; }
    set size(value: number) { this.#items.length = value; }
    static { Repository.instances.clear(); }
    private async source(): Promise<T[]> { return await Promise.resolve(this.#items); }
    has(id: string): boolean;
    has(item: T): boolean;
    has(key: string | T): boolean { return #items in this && !!key; }
}

export @sealed class Exported {}
export default @sealed class {}
const Anonymous = @sealed class {};

export async function* pages<T>(fetch: (page: number) => Promise<T[]>): AsyncIterableIterator<T> {
    let page = 0;
    while (true) {
        const items = await fetch(page++);
        if (!items.length) return;
        yield* items;
    }
}

const handler = async ({ id, ...body }: { id: string; [key: string]: unknown }) => body satisfies object;
const generic = <T,>(value: T): T => value;
const asserted = <const T extends readonly unknown[]>(...values: T) => values as const;

type Unwrap<T> = T extends Promise<infer U extends object> ? Unwrap<U> : T;
type Fn<T> = T extends (this: infer This, ...args: infer A) => infer R ? [This, A, R] : never;
type Nested<T> = T extends Array<infer E extends string ? 1 : 2> ? E : (T extends string ? "s" : "n");
type Getters<T> = { -readonly [K in keyof T as `get${Capitalize<K & string>}`]-?: () => T[K] };
type Tuple = [name: string, age?: number, ...rest: boolean[]];
type Ctor = abstract new (...args: any[]) => object;
type Guard = (value: unknown) => value is string;
type Asserts = (value: unknown) => asserts value is string;
type Query = typeof import("./config");
type Key = keyof typeof defaults;
declare const unique: unique symbol;

enum Color { Red = 1, Green = Red << 1, Blue = "blue".length }
const enum Flags { None, All = ~0 }
declare enum Ambient { A }
declare module "virtual" {
    export const value: number;
}
declare global {
    interface Window { app: unknown }
}
namespace Outer.Inner {
    export abstract class Shape {
        abstract area(): number;
        protected constructor(public readonly sides: number) { super(); }
    }
}
export = Repository;
