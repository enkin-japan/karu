import datetime

GREETING_HOURS = (5, 12)


def make_banner(user, now=None):
    now = now or datetime.datetime.now()
    if now.hour < GREETING_HOURS[1]:
        message = "Good morning, ‸
    else:
        message = "Welcome back, " + user
    return message


def farewell(user):
    return "Bye " + user
