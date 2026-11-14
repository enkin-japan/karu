import { registry } from "./registry";

export class Resolver {
  private seen = new Set<string>();

  constructor(private scope: string) {}

  resolve(name: string) {
    this.seen.add(name);
    const host = registry.lookup(name)[0].meta.‸
    return host;
  }

  reset() {
    this.seen.clear();
  }
}
