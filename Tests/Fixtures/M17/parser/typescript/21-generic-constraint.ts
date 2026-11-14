// Work in progress: generic constraint
// Notes: this module is still being drafted;
export interface HasId { id: string }

export function byId<T extends HasId>(items: T[]) {
  const out = new Map<string, T>();
  for (const it of items) out.set(it.id, it);
  return out;
}

export function first<T>(items: T[]): T | undefined {
  return items[0];
}

export function pluck<T extends ‸
