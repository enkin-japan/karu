"""Cross-file fixture (M17 T17.14): the declarations other files use."""


class User:
    def __init__(self, name: str, age: int = 0):
        self.name = name
        self.age = age

    def greet(self, other: str) -> str:
        return "hi " + other

    def birthday(self) -> int:
        self.age += 1
        return self.age


def make_user(name: str) -> User:
    return User(name)


def make_admin(name: str, level: int = 1) -> User:
    return User(name, level)


VERSION: str = "1.0"
