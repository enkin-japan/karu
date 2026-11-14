export class Poller {
  private timer?: ReturnType<typeof setInterval>;

  constructor(private readonly intervalMs: number) {}

  start(task: () => Promise<void>) {
    this.timer = setInterval(async () => {
      await task();
      this.‸
    }, this.intervalMs);
  }

  stop() {
    clearInterval(this.timer);
  }
}
