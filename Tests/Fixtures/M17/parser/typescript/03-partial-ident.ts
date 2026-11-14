interface Todo { id: number; title: string; done: boolean }

class TodoList {
  private items: Todo[] = [];

  add(todo: Todo): void {
    this.items.push(todo);
  }

  pending(): Todo[] {
    return this.items.filter(t => !t.done);
  }

  titles(): string[] {
    return this.items.ma‸
  }
}
