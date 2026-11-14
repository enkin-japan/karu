export class Stack<T> {
  private data: T[] = [];

  push(value: T): void {
    this.data.push(value);
  }

  pop(): T | undefined {
    if (this.data.length === 0) {
      return undefined;
    }
    const top = this.data[this.data.length - 1];
    this.data.length -= 1;
    retu‸
  }

  size(): number {
    return this.data.length;
  }
}
