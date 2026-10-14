#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm"
PYTHON="${RUNTIME_ROOT}/bin/python"
PIP="${RUNTIME_ROOT}/bin/pip"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

[ -x "${PYTHON}" ] || die "Agent Python missing"

WERKZEUG_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/werkzeug"
[ -f "${WERKZEUG_DIR}/__init__.py" ] || die "Werkzeug not installed"

# 23. Apply Werkzeug CVE-2023-23934 cookie parsing backport
###############################################################################

echo
echo "============================================================"
echo " Applying Werkzeug CVE-2023-23934 backport"
echo "============================================================"

WERKZEUG_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/werkzeug"
WERKZEUG_PATCH_23934="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/CVE-2023-23934.patch"
WERKZEUG_PATCH_23934_SHA256="9e682a6132ffcac899723307e8098ed6adee57cd69218a938c1e5b13c315514e"

[ -d "${WERKZEUG_DIR}" ] \
    || die "Werkzeug directory not found: ${WERKZEUG_DIR}"

[ -f "${WERKZEUG_PATCH_23934}" ] \
    || die "Werkzeug security patch not found: ${WERKZEUG_PATCH_23934}"

WERKZEUG_VERSION="$("${PYTHON}" -c 'import werkzeug; print(werkzeug.__version__)')"

[ "${WERKZEUG_VERSION}" = "1.0.1" ] \
    || die "Unexpected Werkzeug version: ${WERKZEUG_VERSION}"

echo ">>> Werkzeug version verified: ${WERKZEUG_VERSION}"

ACTUAL_WERKZEUG_PATCH_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_23934}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_SHA256}" = "${WERKZEUG_PATCH_23934_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2023-23934 patch: ${ACTUAL_WERKZEUG_PATCH_SHA256}"

if grep -q 'match = _cookie_re.match(b, i)' \
    "${WERKZEUG_DIR}/_internal.py" \
    && grep -q 'b += b";"' "${WERKZEUG_DIR}/_internal.py"; then
    echo ">>> Werkzeug CVE-2023-23934 backport already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_23934}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_23934}"
    )
    echo ">>> Werkzeug CVE-2023-23934 backport applied."
fi

"${PYTHON}" -m py_compile "${WERKZEUG_DIR}/_internal.py"

grep -q 'match = _cookie_re.match(b, i)' \
    "${WERKZEUG_DIR}/_internal.py" \
    || die "Werkzeug CVE-2023-23934 match marker not found"

grep -q 'b += b";"' \
    "${WERKZEUG_DIR}/_internal.py" \
    || die "Werkzeug CVE-2023-23934 input terminator marker not found"

echo ">>> Running CVE-2023-23934 regression test..."

"${PYTHON}" - <<'PYTEST'
from werkzeug.http import parse_cookie

header = '==__Host-eq=bad;__Host-eq=good;'
cookies = parse_cookie(header)

if cookies.get('__Host-eq') != 'good':
    raise RuntimeError(
        "CVE-2023-23934 regression: malformed cookie took precedence"
    )

if cookies.getlist('__Host-eq') != ['good']:
    raise RuntimeError(
        "CVE-2023-23934 regression: malformed cookie was not discarded"
    )

print("CVE-2023-23934 COOKIE PARSING TEST: PASS")
PYTEST

echo ">>> Werkzeug CVE-2023-23934 backport verified."

###############################################################################
# 24. Apply Werkzeug CVE-2023-25577 multipart part limit backport
###############################################################################

echo
echo "============================================================"
echo " Applying Werkzeug CVE-2023-25577 backport"
echo "============================================================"

WERKZEUG_PATCH_25577="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/CVE-2023-25577.patch"
WERKZEUG_PATCH_25577_SHA256="2e40f24444ec9adbc8297550116ceaf17506c8cf6887fa4db4a0201e066866ec"

[ -f "${WERKZEUG_PATCH_25577}" ] \
    || die "Werkzeug security patch not found: ${WERKZEUG_PATCH_25577}"

ACTUAL_WERKZEUG_PATCH_25577_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_25577}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_25577_SHA256}" = "${WERKZEUG_PATCH_25577_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2023-25577 patch: ${ACTUAL_WERKZEUG_PATCH_25577_SHA256}"

if grep -q 'max_form_parts = 1000' \
    "${WERKZEUG_DIR}/wrappers/base_request.py" \
    && grep -q 'parts > self.max_form_parts' \
    "${WERKZEUG_DIR}/formparser.py"; then
    echo ">>> Werkzeug CVE-2023-25577 backport already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_25577}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_25577}"
    )
    echo ">>> Werkzeug CVE-2023-25577 backport applied."
fi

"${PYTHON}" -m py_compile \
    "${WERKZEUG_DIR}/formparser.py" \
    "${WERKZEUG_DIR}/wrappers/base_request.py"

grep -q 'max_form_parts = 1000' \
    "${WERKZEUG_DIR}/wrappers/base_request.py" \
    || die "Werkzeug CVE-2023-25577 request limit marker not found"

grep -q 'parts > self.max_form_parts' \
    "${WERKZEUG_DIR}/formparser.py" \
    || die "Werkzeug CVE-2023-25577 parser limit marker not found"

echo ">>> Running CVE-2023-25577 regression test..."

"${PYTHON}" - <<'PYTEST'
from io import BytesIO

from werkzeug.exceptions import RequestEntityTooLarge
from werkzeug.wrappers import Request


def make_request(count):
    boundary = b"PADITBOUNDARY"
    parts = []

    for i in range(count):
        parts.append(
            b"--" + boundary + b"\r\n"
            b"Content-Disposition: form-data; name=\"field%d\"\r\n"
            b"\r\n"
            b"x\r\n" % i
        )

    parts.append(b"--" + boundary + b"--\r\n")
    data = b"".join(parts)

    return Request.from_values(
        input_stream=BytesIO(data),
        content_length=len(data),
        content_type="multipart/form-data; boundary=PADITBOUNDARY",
        method="POST",
    )


req = make_request(1000)

if len(req.form) != 1000:
    raise RuntimeError(
        "CVE-2023-25577 regression: 1000 multipart parts were not accepted"
    )

req = make_request(1001)

try:
    req.form
except RequestEntityTooLarge:
    pass
else:
    raise RuntimeError(
        "CVE-2023-25577 regression: 1001 multipart parts were accepted"
    )

print("CVE-2023-25577 MULTIPART PART LIMIT TEST: PASS")
PYTEST

echo ">>> Werkzeug CVE-2023-25577 backport verified."

###############################################################################
# 25. Apply Werkzeug CVE-2024-34069 debugger host trust backport
###############################################################################

echo
echo "============================================================"
echo " Applying Werkzeug CVE-2024-34069 backport"
echo "============================================================"

WERKZEUG_PATCH_34069="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/CVE-2024-34069.patch"
WERKZEUG_PATCH_34069_SHA256="69c1b353edb4b311a532c8fd81e9f3de07a30951a064165047250c28f1ca0f8d"

[ -f "${WERKZEUG_PATCH_34069}" ] \
    || die "Werkzeug security patch not found: ${WERKZEUG_PATCH_34069}"

ACTUAL_WERKZEUG_PATCH_34069_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_34069}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_34069_SHA256}" = "${WERKZEUG_PATCH_34069_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2024-34069 patch: ${ACTUAL_WERKZEUG_PATCH_34069_SHA256}"

if grep -q 'self.trusted_hosts = \[".localhost", "127.0.0.1"\]' \
    "${WERKZEUG_DIR}/debug/__init__.py" \
    && grep -q 'application.trusted_hosts.append(hostname)' \
    "${WERKZEUG_DIR}/serving.py"; then
    echo ">>> Werkzeug CVE-2024-34069 backport already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_34069}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_34069}"
    )
    echo ">>> Werkzeug CVE-2024-34069 backport applied."
fi

"${PYTHON}" -m py_compile \
    "${WERKZEUG_DIR}/debug/__init__.py" \
    "${WERKZEUG_DIR}/serving.py"

grep -q 'self.trusted_hosts = \[".localhost", "127.0.0.1"\]' \
    "${WERKZEUG_DIR}/debug/__init__.py" \
    || die "Werkzeug CVE-2024-34069 trusted hosts marker not found"

grep -q 'application.trusted_hosts.append(hostname)' \
    "${WERKZEUG_DIR}/serving.py" \
    || die "Werkzeug CVE-2024-34069 serving hostname marker not found"

[ "$(grep -c 'url: document.location,' \
    "${WERKZEUG_DIR}/debug/shared/debugger.js")" -eq 2 ] \
    || die "Werkzeug CVE-2024-34069 debugger.js markers not found"

echo ">>> Running CVE-2024-34069 regression test..."

"${PYTHON}" - <<'PYTEST'
from werkzeug.debug import DebuggedApplication
from werkzeug.test import Client
from werkzeug.wrappers import Response


def app(environ, start_response):
    response = Response("normal")
    return response(environ, start_response)


debug_app = DebuggedApplication(app, evalex=True)
client = Client(debug_app, Response)

bad = client.get(
    "/console",
    headers={"Host": "attacker.example"},
)

good = client.get(
    "/console",
    headers={"Host": "localhost"},
)

if bad.status_code != 400:
    raise RuntimeError(
        "CVE-2024-34069 regression: untrusted debugger Host was accepted"
    )

if good.status_code != 200:
    raise RuntimeError(
        "CVE-2024-34069 regression: trusted localhost debugger Host was rejected"
    )

print("CVE-2024-34069 DEBUGGER HOST TRUST TEST: PASS")
PYTEST

echo ">>> Werkzeug CVE-2024-34069 backport verified."

###############################################################################
# 26. Apply consolidated Werkzeug safe_join security backports
#     CVE-2024-49766, CVE-2025-66221, CVE-2026-21860,
#     CVE-2026-27199, CVE-2026-102598
###############################################################################

echo
echo "============================================================"
echo " Applying consolidated Werkzeug safe_join security backports"
echo "============================================================"

WERKZEUG_PATCH_SAFE_JOIN="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/safe-join-security-backports.patch"
WERKZEUG_PATCH_SAFE_JOIN_SHA256="acca1e1741f0c0b65b2a67498fce315772b5c9a9c1d763a6bd60af0436543650"

[ -f "${WERKZEUG_PATCH_SAFE_JOIN}" ] \
    || die "Werkzeug safe_join security patch not found: ${WERKZEUG_PATCH_SAFE_JOIN}"

ACTUAL_WERKZEUG_PATCH_SAFE_JOIN_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_SAFE_JOIN}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_SAFE_JOIN_SHA256}" = "${WERKZEUG_PATCH_SAFE_JOIN_SHA256}" ] \
    || die "Unexpected SHA256 for Werkzeug safe_join security patch: ${ACTUAL_WERKZEUG_PATCH_SAFE_JOIN_SHA256}"

if grep -q 'filename.startswith("/")' \
    "${WERKZEUG_DIR}/security.py" \
    && grep -q 'part.partition(":")\[0\]' \
    "${WERKZEUG_DIR}/security.py" \
    && grep -q 'CONOUT\$' \
    "${WERKZEUG_DIR}/security.py"; then
    echo ">>> Werkzeug safe_join security backports already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_SAFE_JOIN}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_SAFE_JOIN}"
    )
    echo ">>> Werkzeug safe_join security backports applied."
fi

"${PYTHON}" -m py_compile "${WERKZEUG_DIR}/security.py"

echo ">>> Running consolidated Werkzeug safe_join regression test..."

"${PYTHON}" - <<'PYTEST'
import ntpath

import werkzeug.security as security
from werkzeug.security import safe_join


assert safe_join("a", "b/c") == "a/b/c"
assert safe_join("a", "../b/c") is None

# CVE-2024-49766
original_isabs = security.os.path.isabs
security.os.path.isabs = ntpath.isabs

try:
    assert safe_join("a", "//b/c") is None
finally:
    security.os.path.isabs = original_isabs

# CVE-2025-66221, CVE-2026-21860,
# CVE-2026-27199, CVE-2026-102598
original_name = security.os.name
security.os.name = "nt"

try:
    blocked = [
        "CON",
        "CON.txt",
        "CON.txt.html",
        "CON  ",
        "CON . txt",
        "CONIN$",
        "CONOUT$",
        "COM1",
        "LPT9",
        u"COM\u00b9",
        u"LPT\u00b3",
        "b/CON",
        "CON:",
        "CON::$DATA",
        "b/CON:",
    ]

    for value in blocked:
        result = safe_join("a", value)

        if result is not None:
            raise RuntimeError(
                "Werkzeug safe_join regression: unsafe path accepted: %r => %r"
                % (value, result)
            )
finally:
    security.os.name = original_name

print("WERKZEUG SAFE_JOIN CONSOLIDATED REGRESSION TEST: PASS")
PYTEST

echo ">>> Werkzeug safe_join security backports verified."

###############################################################################

echo "[PASS] Agent Unix Werkzeug security backports"
