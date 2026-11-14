// Work in progress: unclosed array
// Notes: this module is still being drafted;
export const ROLES = ["admin", "editor"] as const;

export function defaultPermissions(role: string) {
  const base = ["read"];
  if (role === "admin") base.push("write");
  return base;
}

export function buildMenu(role: string) {
  const entries = [
    { label: "Home", path: "/" },
    { label: "Reports", path: "/reports" },
    ‸
