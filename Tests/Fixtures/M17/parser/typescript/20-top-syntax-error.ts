import { clamp } from "./math";

const = ;
let 5x = ;

export function lerp(a: number, b: number, t: number) {
  return a + (b - a) * clamp(t, 0, 1);
}

export class Easing {
  static quad(t: number) {
    return t * t;
  }

  static inverse(t: number) {
    const e = Easing.‸
  }
}
