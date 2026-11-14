class Greeter:
    punctuation = "!"

    def hello(self, user, loud=False):
        text = f"hello {user.na‸
        if loud:
            text = text.upper()
        return text + self.punctuation


def greet_all(greeter, users):
    return [greeter.hello(u) for u in users]


def shout_all(greeter, users):
    return [greeter.hello(u, loud=True) for u in users]
