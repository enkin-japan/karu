// Work in progress: unterminated string
// Notes: this module is still being drafted;
export const GREETINGS = ["hi", "hello"];

export function banner(user: string, hour: number): string {
  let message = "Welcome, ‸
  if (hour < 12) {
    message = "Good morning, " + user;
  }
  return message;
}

export function shout(text: string) {
  return text.toUpperCase();
}
