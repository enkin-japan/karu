export enum Level { Debug, Info, Warn }

export type Handler = (msg: string, level: Level) => void;

export interface Sink { write(line: string): void }

const handlers: Handler[] = [];

export function register(h: Handler) {
  handlers.push(h);
}

export function emit(msg: string, level = Level.Info) {
  for (const h of handlers) {
    h(msg, level);
  }
  const label = Level[level].‸
