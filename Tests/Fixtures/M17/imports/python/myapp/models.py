class User:
    """A user."""

    kind = "user"

    def __init__(self, name: str, age: int = 0):
        self.name = name
        self.age = age
        self.email = ""

    def greet(self) -> str:
        return "hi " + self.name

    @property
    def display(self) -> str:
        return self.name

    @classmethod
    def anonymous(cls) -> "User":
        return cls("anon")

    def _hidden(self):
        pass


class Admin(User):
    def ban(self, user: User) -> bool:
        return True

    def promote(self):
        return Admin("x")
