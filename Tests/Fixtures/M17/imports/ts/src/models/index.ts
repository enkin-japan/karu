export class User {
  private secret = 1;
  static count = 0;
  constructor(public name: string, protected age: number) {}
  greet(): string {
    return "hi " + this.name;
  }
  get label(): string {
    return this.name;
  }
  static create(name: string): User {
    return new User(name, 0);
  }
}

export interface Profile {
  id: number;
  tags: string[];
  owner?: User;
}

export type UserId = number;
