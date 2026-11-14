# Work in progress: module level dot
import settings_loader

config = settings_loader.Settings.load().‸

DEBUG = False


def is_debug():
    return DEBUG


class Flags:
    verbose = True
    quiet = False
