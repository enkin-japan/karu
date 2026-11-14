from .models import User

__all__ = ["make_user"]


def make_user(name: str) -> User:
    return User(name)


def _private_helper():
    return 1
