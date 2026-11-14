# Work in progress: super call
# Notes: this module is still being drafted;
class Base:
    def __init__(self, *args, **kwargs):
        self.args = args


class Child(Base):
    def __init__(self, name, *args, **kwargs):
        super().‸
        self.name = name
        self.tags = [t.strip() for t in kwargs.get("tags", [])]

    def label(self):
        return self.name.title()
