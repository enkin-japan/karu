"""User page rendering."""

DEFAULT_TITLE = "Users"


def render(user_count, user_config):
    header = DEFAULT_TITLE + ": " + str(user_count)
    print(header, user_count)
    return format_page(⟨1⟩)


def refresh(user_cache):
    user_cache.clear()
    return user_cache


def plot(points, scale=(1.0, 2.0), *, line_width=2, line_style="solid"):
    for p in points:
        draw(p, scale, ⟨2⟩)


def send(message: str, retry_limit: int = 3, *, retry_backoff: float = 0.5) -> bool:
    attempts = 0
    while attempts < ⟨3⟩:
        attempts += 1
    return True


def schedule(retry_interval):
    return retry_interval * 2
