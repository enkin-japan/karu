// Work in progress: incomplete generic type
const LIMIT = 100;

export function indexWords(words: string[]) {
  let counts: Map<string, ‸
  const seen = new Set<string>();
  for (const w of words) {
    seen.add(w);
  }
  return seen.size;
}

export function longest(words: string[]) {
  return words.reduce((a, b) => (b.length > a.length ? b : a), "");
}
