from flask import Flask

app = Flask(__name__)


def current_user():
    return None


@app.route("/health")
def health():
    return "ok"


@app.route("/users")
@login_required
‸
