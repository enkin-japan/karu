/**
 * Event bus with typed channels.
 *
 * Block comment lines that look like code must stay comment-coloured:
 *   const x: number = 42; return `template ${x}`;
 *   if (a / b > 2) { /regex/.test(s) }
 */
import { EventEmitter } from 'node:events';

export type Channel = 'open' | 'close' | 'error';
export type Handler<T = unknown> = (payload: T) => void | Promise<void>;
type EventKey<T extends string> = `on${Capitalize<T>}`;
type Path = `/${string}/${number}`;

interface Envelope<T> {
  readonly channel: Channel;
  payload: T;
  sentAt?: Date; // optional
}

enum Level {
  Debug = 'debug',
  Info = 'info', /* trailing
                    block comment */
  Warn = 'warn',
}

const ROUTE_RE = /^\/api\/v(\d+)\/(?<name>[a-z-]+)$/i;
const HALF = 10 / 2 / 1;
const ESCAPED = "a \"quoted\" string with // and /* inside";

function describe<T>(env: Envelope<T>, level: Level = Level.Info): string {
  const when = env.sentAt?.toISOString() ?? 'now';
  return `[${level}] ${env.channel} @ ${when}: ${JSON.stringify(env.payload)}`;
}

function formatList(items: readonly string[], sep = ', '): string {
  return `items(${items.length}): ${items.map((it, i) => `${i + 1}.${it.trim()}`).join(sep)}`;
}

function multiline(user: { name: string; roles: string[] }): string {
  return `
User: ${user.name}
Roles:
${user.roles.map((r) => `  - ${r.toUpperCase()} ${r.length > 3 ? `(long ${r.length / 2})` : ''}`).join('\n')}
Done.`;
}

export class Bus<Events extends Record<Channel, unknown>> {
  private readonly emitter = new EventEmitter();
  private count = 0;

  on<K extends Channel>(channel: K, handler: Handler<Events[K]>): this {
    this.emitter.on(channel, handler as (p: unknown) => void);
    return this;
  }

  emit<K extends Channel>(channel: K, payload: Events[K]): boolean {
    this.count += 1;
    const env: Envelope<Events[K]> = { channel, payload, sentAt: new Date() };
    if (ROUTE_RE.test(String(payload)) && this.count / 2 > 1) {
      console.debug(describe(env, Level.Debug));
    }
    return this.emitter.emit(channel, env);
  }

  ratio(a: number, b: number): number {
    return a / b / (this.count || 1); // division, never a regex
  }
}

export const isRoute = (p: string): p is Path => /^\/[^/]+\/\d+$/.test(p);
export const keyFor = <T extends string>(name: T): EventKey<T> =>
  `on${name.charAt(0).toUpperCase()}${name.slice(1)}` as EventKey<T>;

export { describe, formatList, multiline, HALF, ESCAPED };
