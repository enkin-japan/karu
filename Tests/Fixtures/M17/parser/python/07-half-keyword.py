class Inventory:
    def __init__(self):
        self.stock = {}

    def reserve(self, sku, qty):
        have = self.stock.get(sku, 0)
        if have < qty:
            raise KeyError(sku)
        self.stock[sku] = have - qty
        retu‸

    def release(self, sku, qty):
        self.stock[sku] = self.stock.get(sku, 0) + qty


def restock(inv, sku):
    inv.release(sku, 10)
