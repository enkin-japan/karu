export interface Options { retries: number; verbose: boolean }

export function makeOptions(partial: Partial<Options> = {}) {
  const defaults: Options = {
    retries: 3,
    verbose: false,
  };
  return { ...defaults, ...partial };
}

export function makeClient(baseUrl: string) {
  const config = {
    baseUrl,
    timeout: 5000,
    ‸
