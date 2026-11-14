# Work in progress: lambda
from operator import attrgetter

PAGE_SIZE = 20


def rank_users(users, descending=True):
    ordered = sorted(users, key=lambda u: u.‸
    if descending:
        ordered.reverse()
    return ordered[:PAGE_SIZE]


def names_of(users):
    return [u.name for u in users]
