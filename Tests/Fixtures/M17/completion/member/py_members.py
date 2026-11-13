import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, TypeVar

T = TypeVar("T")


class Client:
    def __init__(self, host: str, timeout: float = 5.0):
        self.host = host
        self.timeout = timeout
        self.retries = 3

    def connect(self) -> bool:
        return self⟨1⟩

    def close(self) -> None:
        self.timeout = 0
        return self⟨2⟩


class Session:
    def __init__(self):
        self.token = ""

    def commit(self):
        return True


@dataclass
class Point:
    x: float
    y: float

    @property
    def norm(self) -> float:
        return (self.x ** 2 + self.y ** 2) ** 0.5


def load_name() -> str:
    return "anonymous"


def make_list():
    return [1, 2, 3]


def first(xs: list[T]) -> T:
    return xs[0]


def literals():
    name = "abc"
    name⟨3⟩
    items = []
    items⟨4⟩
    counts = {}
    counts⟨5⟩


def returns():
    load_name()⟨6⟩
    make_list()⟨7⟩
    first(["a", "b"])⟨8⟩


def instances():
    client = Client("localhost")
    client⟨9⟩
    p = Point(1.0, 2.0)
    p⟨10⟩
    p⟨11⟩


def narrowing(value: int | str, maybe: Optional[Path]):
    if isinstance(value, str):
        value⟨12⟩
    if maybe is not None:
        maybe⟨13⟩


def generics(names: list[str]):
    for n in names:
        n⟨14⟩


def incomplete(data):
    result = compute(data,
    text = "hi"
    text⟨15⟩


def modules():
    os⟨16⟩
    os.path⟨17⟩


def usage(obj, order, user):
    obj.render()
    print(obj.size)
    obj⟨18⟩
    print(order.id, order.total)
    print(user.id, user.email, user.last_login)
    order⟨19⟩


def files(path):
    with open(path) as fh:
        fh⟨20⟩
