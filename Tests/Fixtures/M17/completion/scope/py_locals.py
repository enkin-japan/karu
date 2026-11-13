import json


def checkout(cart):
    total_price = 0
    for item in cart:
        total_price += item.price
    tax = total_price * 0.2
    return tax + ⟨1⟩


def paginate(rows):
    total_pages = len(rows) // 20
    return total_pages


label_text = "global label"


def draw(label_width):
    label_text = "local " + str(label_width)
    print(label_text)
    return ⟨2⟩


def ship(rows):
    for shipment_row in rows:
        print(⟨3⟩)


def rate(rows):
    shipment_rate = 0.5
    return shipment_rate


def read_config(path):
    with open(path) as handle_in:
        return json.load(⟨4⟩)


def write_config(path, data):
    with open(path, "w") as handle_out:
        json.dump(data, handle_out)


def parse(text):
    try:
        return int(text)
    except ValueError as parse_error:
        log(⟨5⟩)
        return None


def count_errors(lines):
    parse_errors_total = 0
    return parse_errors_total


def squares(values):
    return [sq_value * sq_value for sq_value in values if ⟨6⟩]


def split_name(full_name):
    first_name, last_name = full_name.split(" ", 1)
    return first_name.title(), ⟨7⟩


def audit(user):
    last_login = user.seen
    return last_login


def outer():
    retry_budget = 3

    def inner():
        return ⟨8⟩ - 1

    return inner


def backoff():
    retry_backoff = 2
    return retry_backoff


def outer_counts(items):
    count_items = len(items)

    def helper(extra):
        count_total = count_items + extra
        return count_total

    return helper(1) + ⟨9⟩


def profile(user_display_name, user_id):
    print(user_id)
    return ⟨10⟩
