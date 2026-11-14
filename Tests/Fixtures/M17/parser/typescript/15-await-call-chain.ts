// Work in progress: await call chain
import { fetchUser } from "./api";

export async function nickname(id: string) {
  const nick = await fetchUser(id).profile.‸
  return nick ?? "anonymous";
}

export async function nicknames(ids: string[]) {
  const out: string[] = [];
  for (const id of ids) {
    out.push(await nickname(id));
  }
  return out;
}
