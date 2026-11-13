interface User {
  id: number;
  email: string;
  profile?: Profile;
}

interface Profile {
  avatarUrl: string;
  bio: string;
}

interface Circle { kind: 'circle'; radius: number }
interface Square { kind: 'square'; side: number }
type Shape = Circle | Square;

async function load(): Promise<{ data: string[]; total: number }> {
  return { data: [], total: 0 };
}

function wrap<T>(value: T): { value: T; at: Date } {
  return { value, at: new Date() };
}

export function useUser(u: User) {
  u⟨1⟩
  u.profile?⟨2⟩
}

export function area(s: Shape) {
  if ('radius' in s) {
    s⟨3⟩
  }
}

export async function list() {
  const names: Array<string> = [];
  names⟨4⟩
  const { data } = await load();
  data⟨5⟩
  wrap(42).value⟨6⟩
}
