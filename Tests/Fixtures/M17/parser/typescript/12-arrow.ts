// Work in progress: arrow
// Notes: this module is still being drafted;
// names and signatures may change before review.
interface User { id: number; name: string; email?: string }

export function emailsOf(users: User[]): string[] {
  const valid = users.filter(u => u.email !== undefined);
  return valid.map(user => user.‸
}

export function indexById(users: User[]) {
  const index = new Map<number, User>();
  users.forEach(u => index.set(u.id, u));
  return index;
}
