# Work in progress: incomplete import
import os
from typing import Opt‸
from collections import
import

def read_env(name, default=None):
    return os.environ.get(name, default)


class Env:
    prefix = "APP_"

    def get(self, key):
        return read_env(self.prefix + key)
