import yaml

DEFAULTS = {"debug": False, "port": 8080}


def load_config(path):
    with open(path) as fh:
    text = fh.read()
        cfg = yaml.safe_load(text)
    for key, value in DEFAULTS.items():
        cfg.setdefault(key, value)
    return cfg.‸


def save_config(path, cfg):
    with open(path, "w") as fh:
        yaml.safe_dump(cfg, fh)
