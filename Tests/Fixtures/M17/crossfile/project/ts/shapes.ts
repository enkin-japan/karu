export interface Shape {
  area(): number;
}

export class Circle implements Shape {
  constructor(public radius: number) {}
  area(): number { return 3.14 * this.radius * this.radius; }
  scale(factor: number): Circle { return new Circle(this.radius * factor); }
}

export function makeCircle(radius: number): Circle {
  return new Circle(radius);
}

export const unitCircle = new Circle(1);
