# def fake_name():
#     return "this declaration lives in a comment"

DOC = "def ghost_handler(): pass  # text inside a string"


def tally(events):
    fake_count = 0
    ghost_limit = 5
    for event in events:
        # TODO: ⟨1⟩
        message = "processing ⟨2⟩"
        fake_count += 1
    if fake_count > ghost_limit:
        return ⟨3⟩
    return ⟨4⟩


def greet(user_name, user_nickname):
    return f"Hello {⟨5⟩}!"
