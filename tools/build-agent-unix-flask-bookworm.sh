#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm"
BUILD_ROOT="$(mktemp -d /tmp/padit-agent-unix-flask-XXXXXXXX)"

PYTHON="${RUNTIME_ROOT}/bin/python"
PIP="${RUNTIME_ROOT}/bin/pip"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

run() {
    echo ">>> $*"
    "$@"
}

[ -x "${PYTHON}" ] || die "Agent Python missing"

# 14. Build Flask 1.1.4 with session security backports
###############################################################################

echo
echo "============================================================"
echo " Building patched Flask 1.1.4 from source"
echo "============================================================"

FLASK_VERSION="1.1.4"
FLASK_BUILD_DIR="${BUILD_ROOT}/flask-${FLASK_VERSION}-source"
FLASK_SDIST_SHA256="0fbeb6180d383a9186d0d6ed954e0042ad9f18e0e8de088b2b419d526927d196"

FLASK_PATCH="${REPO_ROOT}/utils/patch-flask-1.1.4/CVE-2023-30861-CVE-2026-27205.patch"
FLASK_PATCH_SHA256="4b2a84ccdc10495db631719f1b58fa16e2c4a7def27695ff39e6a0e3c1cc3312"

[ -f "${FLASK_PATCH}" ] \
    || die "Flask security patch not found: ${FLASK_PATCH}"

ACTUAL_FLASK_PATCH_SHA256="$(
    sha256sum "${FLASK_PATCH}" | awk '{print $1}'
)"

[ "${ACTUAL_FLASK_PATCH_SHA256}" = "${FLASK_PATCH_SHA256}" ] \
    || die "Unexpected SHA256 for Flask patch: ${ACTUAL_FLASK_PATCH_SHA256}"

[ ! -e "${FLASK_BUILD_DIR}" ] || die "Flask build directory exists"
mkdir -p "${FLASK_BUILD_DIR}"
cd "${FLASK_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "Flask==${FLASK_VERSION}"

FLASK_SDIST="Flask-${FLASK_VERSION}.tar.gz"

[ -f "${FLASK_SDIST}" ] \
    || die "Flask source archive not found: ${FLASK_SDIST}"

ACTUAL_FLASK_SDIST_SHA256="$(
    sha256sum "${FLASK_SDIST}" | awk '{print $1}'
)"

[ "${ACTUAL_FLASK_SDIST_SHA256}" = "${FLASK_SDIST_SHA256}" ] \
    || die "Unexpected SHA256 for Flask source archive: ${ACTUAL_FLASK_SDIST_SHA256}"

tar -xf "${FLASK_SDIST}"

FLASK_SRC_DIR="${FLASK_BUILD_DIR}/Flask-${FLASK_VERSION}"

[ -d "${FLASK_SRC_DIR}" ] \
    || die "Flask source directory not found: ${FLASK_SRC_DIR}"

(
    cd "${FLASK_SRC_DIR}"
    patch --dry-run -p1 < "${FLASK_PATCH}" >/dev/null
    patch -p1 < "${FLASK_PATCH}"
)

echo ">>> Flask CVE-2023-30861/CVE-2026-27205 backport applied."

FLASK_WHEELHOUSE="${FLASK_BUILD_DIR}/wheelhouse"
mkdir -p "${FLASK_WHEELHOUSE}"

run "${PIP}" wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${FLASK_WHEELHOUSE}" \
    "${FLASK_SRC_DIR}"

run "${PIP}" install \
    --force-reinstall \
    --no-index \
    --no-deps \
    --find-links "${FLASK_WHEELHOUSE}" \
    "Flask==${FLASK_VERSION}"

"${PYTHON}" - <<'PYFLASK'
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
PYFLASK

echo ">>> Flask 1.1.4 patched build verified."

###############################################################################

echo "[PASS] Agent Unix Flask security build"
