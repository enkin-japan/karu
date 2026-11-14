import registry

_cache = {}


class Resolver:
    def __init__(self, scope):
        self.scope = scope

    def resolve(self, name, default=None):
        key = (self.scope, name)
        if key in _cache:
            return _cache[key]
        host = registry.lookup(name)[0].meta.‸
        return default or host
