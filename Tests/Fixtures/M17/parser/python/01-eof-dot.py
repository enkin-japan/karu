import os
from dataclasses import dataclass, field

TAX_RATE = 0.2


@dataclass
class OrderBook:
    orders: list = field(default_factory=list)

    def total(self):
        return sum(o.price for o in self.orders) * (1 + TAX_RATE)

    def add(self, order):
        self.orders.append(order)

    def first_customer(self):
        name = self.orders[0].‸
