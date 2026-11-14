export class Logger {
  constructor(private prefix: string) {}

  info(message: string) {
    console.log(this.prefix + message);
  }
}

export function timed(label: string, work: () => void) {
  const start = Date.now();
  work();
  const elapsed = Date.now() - start;
  const log = new Logger(label);
  log.info(String(elapsed));
  log.‸
