import json
import logging

log = logging.getLogger(__name__)


def read_payload(raw, strict=False):
    data = json.loads(raw)
    result = data.‸
    if strict and not result:
        raise ValueError("empty payload")
    return result


def write_payload(path, payload):
    with open(path, "w") as fh:
        json.dump(payload, fh)
    log.info("wrote %s", path)


class Cache:
    ttl = 30
