// Work in progress: missing open brace
// Notes: this module is still being drafted;
export interface Token { kind: string; text: string }

export function tokenize(source: string): Token[]
  const tokens: Token[] = [];
  for (const word of source.split(" ")) {
    tokens.push({ kind: "word", text: word.‸ });
  }
  return tokens;
}

export function countTokens(source: string) {
  return tokenize(source).length;
}
