import { Order } from "./order";

export const TAX_RATE = 0.2;

export interface Summary {
  count: number;
  total: number;
}

export function summarize(orders: Order[]): Summary {
  const total = orders.reduce((sum, o) => sum + o.price, 0);
  return { count: orders.length, total };
}

export function firstCustomer(orders: Order[]) {
  const name = orders[0].customer.‸
