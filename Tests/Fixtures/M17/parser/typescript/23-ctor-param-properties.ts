export interface Transport { send(msg: string): void }

export class Mailer {
  private queue: string[] = [];
  static instances = 0;
  readonly maxBatch: number = 50;

  constructor(
    private readonly transport: Transport,
    public sender: string,
    protected retries = 3,
  ) {
    Mailer.instances++;
    this.transport.‸
  }

  enqueue(msg: string) {
    this.queue.push(msg);
  }
}
