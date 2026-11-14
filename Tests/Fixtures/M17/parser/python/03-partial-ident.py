from decimal import Decimal

CURRENCY = "USD"


def summarize_cart(cart, coupon=None):
    lines = []
    for item in cart.ite‸
        lines.append(f"{item.name}: {item.qty}")
    return "\n".join(lines)


def apply_coupon(price, coupon):
    if coupon is None:
        return price
    return price * Decimal("0.9")
