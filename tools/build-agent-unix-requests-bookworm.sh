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

REQUESTS_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/requests"
[ -f "${REQUESTS_DIR}/sessions.py" ] || die "Requests not installed"

# 19. Apply requests CVE-2023-32681 proxy authorization leak backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2023-32681 backport"
echo "============================================================"

REQUESTS_PATCH_32681="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2023-32681.patch"
REQUESTS_PATCH_32681_SHA256="003eb163893c401f94e65172b6e11e659d4a5983e8cf6f85eed43e674dd8eca2"

[ -f "${REQUESTS_PATCH_32681}" ] \
    || die "requests CVE-2023-32681 patch not found: ${REQUESTS_PATCH_32681}"

ACTUAL_REQUESTS_PATCH_32681_SHA256="$(
    sha256sum "${REQUESTS_PATCH_32681}" | awk '{print $1}'
)"

[ "${ACTUAL_REQUESTS_PATCH_32681_SHA256}" = "${REQUESTS_PATCH_32681_SHA256}" ] \
    || die "Unexpected SHA256 for requests CVE-2023-32681 patch: ${ACTUAL_REQUESTS_PATCH_32681_SHA256}"

if grep -q "if not scheme.startswith('https') and username and password:" \
    "${REQUESTS_DIR}/sessions.py"; then
    echo ">>> requests CVE-2023-32681 backport already present."
else
    (
        cd "${REQUESTS_DIR}"
        patch --dry-run -p1 < "${REQUESTS_PATCH_32681}" >/dev/null
        patch -p1 < "${REQUESTS_PATCH_32681}"
    )
    echo ">>> requests CVE-2023-32681 backport applied."
fi

"${PYTHON}" -m py_compile "${REQUESTS_DIR}/sessions.py"

echo ">>> Running CVE-2023-32681 regression test..."

"${PYTHON}" - <<'PYTEST'
import requests

session = requests.Session()
session.trust_env = False

proxies = {
    "http": "http://test:pass@localhost:8080",
    "https": "http://test:pass@localhost:8090",
}

cases = [
    ("http://example.com", True),
    ("https://example.com", False),
]

for url, should_have_auth in cases:
    req = requests.Request("GET", url)
    prep = req.prepare()

    session.rebuild_proxies(prep, proxies)

    has_auth = "Proxy-Authorization" in prep.headers

    if has_auth != should_have_auth:
        raise RuntimeError(
            "Unexpected Proxy-Authorization state for %s: %r"
            % (url, prep.headers.get("Proxy-Authorization"))
        )

print("CVE-2023-32681 PROXY AUTH LEAK TEST: PASS")
PYTEST

echo ">>> requests CVE-2023-32681 backport verified."

###############################################################################
# 20. Apply requests CVE-2024-35195 TLS pool isolation backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2024-35195 backport"
echo "============================================================"

REQUESTS_PATCH_35195="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2024-35195.patch"
REQUESTS_PATCH_35195_SHA256="4af162e6e503f464ae8a62fb208e89d4427f3349606014c2c22901f02a8451d8"

[ -f "${REQUESTS_PATCH_35195}" ] \
    || die "requests security patch not found: ${REQUESTS_PATCH_35195}"

ACTUAL_REQUESTS_PATCH_SHA256="$(
    sha256sum "${REQUESTS_PATCH_35195}" | awk '{print $1}'
)"

[ "${ACTUAL_REQUESTS_PATCH_SHA256}" = "${REQUESTS_PATCH_35195_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2024-35195 patch: ${ACTUAL_REQUESTS_PATCH_SHA256}"

if grep -q 'def _urllib3_request_context(request, verify):' \
    "${REQUESTS_DIR}/adapters.py" \
    && grep -q 'self._get_connection(request, verify, proxies)' \
    "${REQUESTS_DIR}/adapters.py"; then
    echo ">>> requests CVE-2024-35195 backport already present."
else
    (
        cd "${REQUESTS_DIR}"
        patch --dry-run -p1 < "${REQUESTS_PATCH_35195}" >/dev/null
        patch -p1 < "${REQUESTS_PATCH_35195}"
    )
    echo ">>> requests CVE-2024-35195 backport applied."
fi

"${PYTHON}" -m py_compile "${REQUESTS_DIR}/adapters.py"

grep -q 'def _urllib3_request_context(request, verify):' \
    "${REQUESTS_DIR}/adapters.py" \
    || die "requests TLS pool context marker not found"

grep -q 'self._get_connection(request, verify, proxies)' \
    "${REQUESTS_DIR}/adapters.py" \
    || die "requests TLS-aware connection marker not found"

echo ">>> Running CVE-2024-35195 regression test..."

"${PYTHON}" - <<'PYTEST'
import requests
from requests.adapters import HTTPAdapter

req = requests.Request(
    "GET",
    "https://example.invalid/test"
).prepare()

adapter = HTTPAdapter()

conn_unverified = adapter._get_connection(req, False)
conn_verified = adapter._get_connection(req, True)

if conn_unverified is conn_verified:
    raise RuntimeError(
        "CVE-2024-35195 regression: verify=False and verify=True reused the same pool"
    )

print("CVE-2024-35195 POOL ISOLATION TEST: PASS")
PYTEST

echo ">>> requests CVE-2024-35195 backport verified."

###############################################################################
# 21. Apply requests CVE-2024-47081 netrc hostname backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2024-47081 backport"
echo "============================================================"

REQUESTS_PATCH_47081="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2024-47081.patch"
REQUESTS_PATCH_47081_SHA256="1ffc179dae25541aaefb867361535d4fda56a51462e988cc06c9df330ab23196"

[ -f "${REQUESTS_PATCH_47081}" ] \
    || die "requests security patch not found: ${REQUESTS_PATCH_47081}"

ACTUAL_REQUESTS_PATCH_SHA256="$(
    sha256sum "${REQUESTS_PATCH_47081}" | awk '{print $1}'
)"

[ "${ACTUAL_REQUESTS_PATCH_SHA256}" = "${REQUESTS_PATCH_47081_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2024-47081 patch: ${ACTUAL_REQUESTS_PATCH_SHA256}"

if grep -q 'host = ri.hostname' \
    "${REQUESTS_DIR}/utils.py"; then
    echo ">>> requests CVE-2024-47081 backport already present."
else
    (
        cd "${REQUESTS_DIR}"
        patch --dry-run -p1 < "${REQUESTS_PATCH_47081}" >/dev/null
        patch -p1 < "${REQUESTS_PATCH_47081}"
    )
    echo ">>> requests CVE-2024-47081 backport applied."
fi

"${PYTHON}" -m py_compile "${REQUESTS_DIR}/utils.py"

grep -q 'host = ri.hostname' \
    "${REQUESTS_DIR}/utils.py" \
    || die "requests netrc hostname marker not found"

echo ">>> Running CVE-2024-47081 regression test..."

"${PYTHON}" - <<'PYTEST'
import os
import tempfile
import requests

fd, path = tempfile.mkstemp(prefix='padit-netrc-')
os.close(fd)

with open(path, 'w') as f:
    f.write(
        'machine example.com\n'
        'login padituser\n'
        'password paditpass\n'
    )

os.chmod(path, 0600)
os.environ['NETRC'] = path

try:
    auth = requests.utils.get_netrc_auth(
        'https://user:pass@example.com:8443/test'
    )

    if auth != ('padituser', 'paditpass'):
        raise RuntimeError(
            "CVE-2024-47081 regression: hostname netrc lookup failed"
        )

    print("CVE-2024-47081 NETRC HOSTNAME TEST: PASS")
finally:
    os.unlink(path)
    os.environ.pop('NETRC', None)
PYTEST

echo ">>> requests CVE-2024-47081 backport verified."

###############################################################################
# 22. Apply requests CVE-2026-25645 temporary-file backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2026-25645 backport"
echo "============================================================"

REQUESTS_PATCH_25645="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2026-25645.patch"
REQUESTS_PATCH_25645_SHA256="8b3a91cf7e963b2fa50311525db2b23f297c966fd1860042190019443384937a"

[ -f "${REQUESTS_PATCH_25645}" ] \
    || die "requests security patch not found: ${REQUESTS_PATCH_25645}"

ACTUAL_REQUESTS_PATCH_SHA256="$(
    sha256sum "${REQUESTS_PATCH_25645}" | awk '{print $1}'
)"

[ "${ACTUAL_REQUESTS_PATCH_SHA256}" = "${REQUESTS_PATCH_25645_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2026-25645 patch: ${ACTUAL_REQUESTS_PATCH_SHA256}"

if grep -q 'fd, extracted_path = tempfile.mkstemp(suffix=suffix)' \
    "${REQUESTS_DIR}/utils.py"; then
    echo ">>> requests CVE-2026-25645 backport already present."
else
    (
        cd "${REQUESTS_DIR}"
        patch --dry-run -p1 < "${REQUESTS_PATCH_25645}" >/dev/null
        patch -p1 < "${REQUESTS_PATCH_25645}"
    )
    echo ">>> requests CVE-2026-25645 backport applied."
fi

"${PYTHON}" -m py_compile "${REQUESTS_DIR}/utils.py"

grep -q 'fd, extracted_path = tempfile.mkstemp(suffix=suffix)' \
    "${REQUESTS_DIR}/utils.py" \
    || die "requests secure temporary-file marker not found"

echo ">>> Running CVE-2026-25645 regression test..."

"${PYTHON}" - <<'PYTEST'
import os
import tempfile
import zipfile
import requests

fd, zip_path = tempfile.mkstemp(prefix='padit-requests-', suffix='.zip')
os.close(fd)

payload = 'PADIT-CVE-2026-25645'

try:
    z = zipfile.ZipFile(zip_path, 'w')
    z.writestr('nested/test.txt', payload)
    z.close()

    virtual_path = zip_path + os.sep + 'nested' + os.sep + 'test.txt'

    extracted1 = requests.utils.extract_zipped_paths(virtual_path)
    extracted2 = requests.utils.extract_zipped_paths(virtual_path)

    if extracted1 == extracted2:
        raise RuntimeError(
            "CVE-2026-25645 regression: temporary path was reused"
        )

    for extracted in (extracted1, extracted2):
        if not os.path.isfile(extracted):
            raise RuntimeError(
                "CVE-2026-25645 regression: extracted file missing"
            )
        with open(extracted, 'rb') as f:
            if f.read() != payload:
                raise RuntimeError(
                    "CVE-2026-25645 regression: extracted content mismatch"
                )

    print("CVE-2026-25645 TEMP FILE UNIQUENESS TEST: PASS")

finally:
    for name in ('extracted1', 'extracted2'):
        if name in locals():
            extracted = locals()[name]
            if os.path.exists(extracted):
                os.unlink(extracted)

    if os.path.exists(zip_path):
        os.unlink(zip_path)
PYTEST

echo ">>> requests CVE-2026-25645 backport verified."

###############################################################################

echo "[PASS] Agent Unix Requests security backports"
