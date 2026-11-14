"""T17.11a grammar coverage (valid Python 3.13): match patterns, walrus,
f-string internals, async, decorators, PEP 695."""
import asyncio
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Point:
    x: int
    y: int = 0


def describe(command: Any) -> str:
    match command:
        case None | True | False:
            return "constant"
        case 0 | -1 | 1.5 | 2 + 3j | -1 - 2j:
            return "number"
        case "go" | b"stop":
            return "literal"
        case Point(x=0, y=0):
            return "origin"
        case Point(x, y=0) if x > 0:
            return f"on axis {x}"
        case Point(1, 2) as p:
            return repr(p)
        case [first, *rest]:
            return f"{first} and {len(rest)} more"
        case (a, b, *_):
            return f"{a}{b}"
        case []:
            return "empty"
        case {"kind": "move", "to": (dx, dy), **others}:
            return f"move {dx},{dy} {others}"
        case {}:
            return "mapping"
        case asyncio.Queue():
            return "queue"
        case str() | bytes():
            return "text"
        case [Point(x=0) | Point(y=0), _]:
            return "pair"
        case _:
            return "other"


def tuples(value):
    match value:
        case 1, 2:
            return 0
        case *head, last:
            return last
    match value, len(value):
        case (x, 3):
            return x


def walrus(items):
    if (n := len(items)) > 10:
        print(n)
    while chunk := items[:2]:
        items = items[2:]
    total = [y for x in items if (y := x * 2) > 3]
    print(f"{(z := 5)}", z, total)
    return [last := i for i in range(3)], last


def formats(value, width, precision, name):
    print(f"{value:>{width}.{precision}f}")
    print(f"{value!r:^20}", f"{value=}", f"{value = !s:>10}")
    print(f"{value:#x} and {width:#o}", f'{name:#b}')
    print(f"{'nested'} {name!a} {{literal}} {value:{width}}")
    print(f"""multi
{value:>{width}}
line""")
    return rf"\d{value}", Rb"\x00", f"{value:%Y-%m-%d %H:%M}"


class Service:
    @property
    def ready(self) -> bool:
        return True

    @staticmethod
    @functools_cache
    async def fetch[T](url: str, *, retries: int = 3, **kw: T) -> T:
        async with session(url) as (reader, writer), other() as o:
            async for line in reader:
                await asyncio.sleep(0)
                yield line
        return await asyncio.gather(*[x async for x in reader if await x])

    def gen(self, /, *args):
        yield from args
        x = yield
        return lambda a, /, b=1, *c, d, **e: (a, b, c, d, e)


type Pair[K, V = int] = tuple[K, V]
type Callback = Callable[[int], None]


def generic[T: (int, str), *Ts, **P](x: T, *args: *Ts) -> T:
    global counter
    try:
        pass
    except* ValueError as group:
        raise RuntimeError("bad") from group
    except* (TypeError, KeyError):
        pass
    else:
        del x, args
    finally:
        assert counter, "no counter"
    with (open("a") as f1,
          open("b") as f2):
        nonlocal_value = f1.read() + f2.read()
    return nonlocal_value


matrix = [[1, 2], [3, 4]] @ [[5], [6]]
matrix @= matrix
sliced = matrix[::2, 1:, ...]
unpacked = {**{"a": 1}, "b": 2}, {*range(3), 4}, (*range(2),)
conditional = 1 if matrix else 2 if sliced else 3
chained = 1 < 2 <= 3 != 4 is not None
negated = not unpacked and conditional or chained
print(*matrix, sep="\n", end="")
