"""Coverage of Python syntax for the hand-written prototype (valid code)."""
from __future__ import annotations
import os.path as osp, sys
from .pkg import (a as b,
                  c)
from .. import d

type Pair[T] = tuple[T, T]
X: int
Y: dict[str, list[int]] = {}
a = b = c = 1
x, *rest = [1, 2, 3]
(p, q), r = (1, 2), 3
total += 1; count -= 2
matrix @= other

@decorator(arg, key=value)
@other.attr
class Base(Generic[T], metaclass=Meta, **extra):
    """Doc."""
    field: ClassVar[int] = 0

    def __init__(self, a, /, b=1, *args, c, d=2, **kwargs) -> None:
        super().__init__()
        self.a = a if a is not None else b
        self.items = [i for i in range(10) if i % 2 if i > 3]
        self.table = {k: v for k, v in zip("ab", (1, 2))}
        self.uniq = {y for y in self.items}
        self.gen = (z * 2 for z in self.items)

    @property
    def value(self) -> int:
        return self._value

    async def run(self, *, timeout: float = 1.0):
        async with lock as held, other():
            async for item in stream():
                await process(item)
        return [await f() for f in fns]

    def gen(self):
        yield 1
        x = yield
        yield from range(3)


def outer(n):
    count = 0

    def inner():
        nonlocal count
        global VALUE
        count += 1
        return count

    while n > 0:
        n -= 1
        if n == 5:
            continue
        elif n == 3:
            break
    else:
        pass
    for i, (j, k) in enumerate(pairs):
        print(i, j, k, sep=", ", end="\n")
    else:
        del pairs[0], cache["k"]
    try:
        risky()
    except (ValueError, TypeError) as exc:
        raise RuntimeError("bad") from exc
    except OSError:
        pass
    else:
        assert n == 0, "never"
    finally:
        cleanup()
    with open("a") as fa, open("b") as fb:
        data = fa.read()[1:-1:2] + fb.read()[::2]
    with (open("a") as fa,
          open("b") as fb):
        pass
    if (m := pattern.match(data)) and not m.group(0) in {"a", "b"} or 1 < n <= 10 != 3:
        return lambda x, *ys, z=1, **kw: (x, ys, z, kw)
    s = f"{n!r:>{width}} {data['k']:.2f} {{literal}} {n=}"
    t = rb'\d+' b"concat" b'more'
    u = """multi
line""" + '''other'''
    v = -n ** 2 + ~n // 3 % 2 << 1 >> 2 & 3 | 4 ^ 5
    w = not n is not None
    print(*args, **kwargs)
    return inner


match command.split():
    case [action]:
        pass
    case [action, obj] if obj:
        pass
    case Point(x=0, y=0) | {"k": _, **others} as whole:
        pass
    case _:
        pass

if __name__ == "__main__":
    outer(10)
