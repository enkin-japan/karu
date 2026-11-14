import os

LOG_LEVELS = {"debug": 10, "info": 20}


def load_defaults():
    return {"port": 8080}


def make_settings(env, debug=False):
    base = load_defaults()
    settings = {
        "env": env,
        "debug": debug,
        "home": os.environ.get("HOME"),
        ‸
