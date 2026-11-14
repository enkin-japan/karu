from typing import Dict, Optional

Registry = Dict[str, int]


def connect(host: str, port: int = 5432):
    timeout: Opt‸
    retries = 3
    return (host, port, retries)


class Pool:
    size: int = 4

    def acquire(self):
        return self.size
