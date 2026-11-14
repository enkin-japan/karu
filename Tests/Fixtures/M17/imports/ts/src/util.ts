export * from "./models";
export { Admin as SuperUser } from "./models/admin";

export function helper(n: number): string {
  return String(n);
}

export const settings = { debug: true, level: 3 };

export default function main(): void {}
