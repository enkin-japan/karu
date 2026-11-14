const VERSION = "1.4.0";
}

export function versionParts() {
  return VERSION.split(".");
}

);

export class Release {
  constructor(public readonly tag: string, public notes: string[] = []) {}

  summary() {
    return this.notes.‸
  }
}
