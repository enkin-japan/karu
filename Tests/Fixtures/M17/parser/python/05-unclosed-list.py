# Work in progress: unclosed list
import sys

DEFAULT_HOSTS = ["localhost"]


def normalize(prefix):
    return prefix.rstrip("/")


def build_routes(prefix, version):
    routes = [
        f"{prefix}/v{version}/users",
        f"{prefix}/v{version}/orders",
        ‸
