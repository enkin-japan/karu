from ..models import User
from .. import services


def find(name: str) -> User:
    return services.make_user(name)
