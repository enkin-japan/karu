type DisplayMode = 'grid' | 'list';
type DisplayDensity = 'compact' | 'cozy';

interface Point { originX: number; originY: number }
interface ApiClient { get(path: string): Promise<unknown> }
interface RetryPolicy { attempts: number }

declare function configure(...args: unknown[]): void;

export function mergeRecords<TRecord>(baseRecord: TRecord, patchRecord: Partial<TRecord>): TRecord {
  return { ...baseRecord, ...⟨1⟩ };
}

export class Fetcher {
  constructor(private readonly apiClient: ApiClient, private retryPolicy: RetryPolicy) {
    configure(apiClient, ⟨2⟩);
  }
}

export function draw({ originX, originY }: Point, scale = 1): number {
  return originX * scale + ⟨3⟩;
}

export function fetchPage(pageIndex?: number, pageSizeHint = 20): string {
  return `${pageIndex ?? 0}/${⟨4⟩}`;
}

export let mode: Disp⟨5⟩ = 'grid';
export let density: DisplayDensity = 'cozy';

/* function fakeFn() { return 1; } — a declaration inside a comment */
export const note = "function fakeHelper() {}";

export function flags(fakeFlag: boolean): boolean {
  // fake⟨6⟩
  const msg = `fake ⟨7⟩ text`;
  return msg.length > 0 && ⟨8⟩;
}
