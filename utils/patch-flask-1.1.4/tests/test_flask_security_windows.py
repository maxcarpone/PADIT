import flask

from flask import Flask
from flask import session
from flask.globals import _request_ctx_stack
from flask.sessions import SecureCookieSession

expected = "1.1.4"

if flask.__version__ != expected:
    raise SystemExit(
        "Unexpected Flask version: %s (expected %s)"
        % (flask.__version__, expected)
    )

# CVE-2023-30861:
# A permanent session refreshed without explicit access must still emit
# Vary: Cookie when Flask rewrites the cookie.
app = Flask(__name__)
app.secret_key = "padit-regression-test"
app.config["SESSION_REFRESH_EACH_REQUEST"] = True

test_session = SecureCookieSession(
    {"_permanent": True, "user": "alice"}
)
test_session.modified = False
test_session.accessed = False

response = app.response_class()
app.session_interface.save_session(app, test_session, response)

if not response.headers.get("Set-Cookie"):
    raise AssertionError(
        "Permanent session refresh did not emit Set-Cookie"
    )

if "Cookie" not in response.vary:
    raise AssertionError(
        "Vary: Cookie missing when session cookie was refreshed"
    )

# Deleting a modified empty session cookie must also vary on Cookie.
empty_session = SecureCookieSession()
empty_session.modified = True
empty_session.accessed = False

delete_response = app.response_class()
app.session_interface.save_session(
    app, empty_session, delete_response
)

if "Cookie" not in delete_response.vary:
    raise AssertionError(
        "Vary: Cookie missing when session cookie was deleted"
    )

# CVE-2026-27205:
# Resolving flask.session must mark the session accessed regardless
# of the particular mapping operation subsequently performed.
with app.test_request_context("/"):
    ctx = _request_ctx_stack.top

    ctx.session["user"] = "alice"
    ctx.session.modified = False
    ctx.session.accessed = False

    if ("user" in session) is not True:
        raise AssertionError("session containment lookup failed")

    if not ctx.session.accessed:
        raise AssertionError(
            "session containment lookup did not mark session accessed"
        )

    ctx.session.accessed = False

    if len(session) != 1:
        raise AssertionError(
            "Unexpected session length: %r" % len(session)
        )

    if not ctx.session.accessed:
        raise AssertionError(
            "session len lookup did not mark session accessed"
        )

# Internal request processing itself must not spuriously mark an unused
# session as accessed.
app2 = Flask("padit-no-session-access")
app2.secret_key = "padit-regression-test"

@app2.route("/")
def no_session_access():
    return "ok"

client = app2.test_client()
response = client.get("/")

if "Cookie" in response.vary:
    raise AssertionError(
        "Unused session was spuriously marked as accessed"
    )

print(">>> Flask version verified: %s" % flask.__version__)
print("CVE-2023-30861 REGRESSION TEST: PASS")
print("CVE-2026-27205 IN-OPERATOR TEST: PASS")
print("CVE-2026-27205 LEN TEST: PASS")
print("FLASK UNUSED SESSION COMPATIBILITY TEST: PASS")