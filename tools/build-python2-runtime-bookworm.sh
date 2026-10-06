#!/bin/bash
set -e

###############################################################################
# PADIT - Python 2.7 compatibility runtime for Debian 12 Bookworm
#
# Transitional compatibility runtime for PADIT Server 1.8.2.
#
# IMPORTANT:
#   Python 2.7 is EOL.
#   This runtime is a compatibility layer, NOT the final security architecture.
#
# Output:
#   build/python2-runtime-server-bookworm/
#
###############################################################################

PYTHON_VERSION="2.7.18"

BUILD_ROOT="/tmp/wapt-python2-build"
PYTHON_SRC="${BUILD_ROOT}/Python-${PYTHON_VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="${REPO_ROOT}/build/python2-runtime-server-bookworm"

PIP_VERSION="20.3.4"
SETUPTOOLS_VERSION="44.1.1"
WHEEL_VERSION="0.34.2"

PYTHON="${RUNTIME_ROOT}/bin/python"
PIP="${RUNTIME_ROOT}/bin/pip"

###############################################################################
# Helpers
###############################################################################

die()
{
    echo
    echo "ERROR: $*"
    exit 1
}

run()
{
    echo
    echo ">>> $*"
    "$@"
}

###############################################################################
# Header
###############################################################################

echo "============================================================"
echo " PADIT Python 2 compatibility runtime"
echo " Debian 12 Bookworm"
echo " PADIT Server"
echo " Python ${PYTHON_VERSION}"
echo "============================================================"

###############################################################################
# 1. Checks
###############################################################################

[ "$(id -u)" -eq 0 ] || die "run this script as root (sudo)."

[ -d "${REPO_ROOT}" ] || die "repository not found: ${REPO_ROOT}"

[ -f "${REPO_ROOT}/requirements-server.txt" ] \
    || die "requirements-server.txt not found"

[ -f "${REPO_ROOT}/utils/patch-cryptography/__init__.py" ] \
    || die "PADIT cryptography patch not found"

[ -f "${REPO_ROOT}/utils/patch-cryptography/verification.py" ] \
    || die "PADIT cryptography verification patch not found"

echo
echo ">>> Repository:"
echo "    ${REPO_ROOT}"

echo
echo ">>> Build output:"
echo "    ${RUNTIME_ROOT}"

###############################################################################
# 2. Build dependencies
###############################################################################

echo
echo ">>> Installing build dependencies..."

apt-get update

apt-get install -y \
    build-essential \
    wget \
    curl \
    ca-certificates \
    xz-utils \
    tar \
    bzip2 \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libffi-dev \
    libncurses5-dev \
    libncursesw5-dev \
    libgdbm-dev \
    liblzma-dev \
    tk-dev \
    uuid-dev \
    libpq-dev \
    libldap2-dev \
    libsasl2-dev \
    libkrb5-dev

###############################################################################
# 3. Prepare CPython source
###############################################################################

echo
echo ">>> Preparing CPython ${PYTHON_VERSION}..."

mkdir -p "${BUILD_ROOT}"
cd "${BUILD_ROOT}"

ARCHIVE="Python-${PYTHON_VERSION}.tgz"
URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/${ARCHIVE}"

if [ ! -f "${ARCHIVE}" ]; then
    echo
    echo ">>> Downloading:"
    echo "    ${URL}"

    curl -fL "${URL}" -o "${ARCHIVE}"
fi

echo
echo ">>> CPython archive checksum:"
sha256sum "${ARCHIVE}"

if [ ! -d "${PYTHON_SRC}" ]; then
    tar xf "${ARCHIVE}"
fi

###############################################################################
# 4. Clean previous CPython build
###############################################################################

cd "${PYTHON_SRC}"

echo
echo ">>> Cleaning CPython build..."

make distclean >/dev/null 2>&1 || true

###############################################################################
# 5. Configure
###############################################################################

echo
echo ">>> Configuring CPython..."

./configure \
    --prefix="${RUNTIME_ROOT}" \
    --enable-unicode=ucs4 \
    --with-ensurepip=no

###############################################################################
# 6. Compile
###############################################################################

echo
echo ">>> Compiling CPython..."

make -j"$(nproc)"

###############################################################################
# 7. Install runtime
###############################################################################

echo
echo ">>> Installing runtime into:"
echo "    ${RUNTIME_ROOT}"

rm -rf "${RUNTIME_ROOT}"

make install

###############################################################################
# 8. Install Python 2 compatible packaging stack
###############################################################################

echo
echo ">>> Installing pip ${PIP_VERSION}..."

cd "${BUILD_ROOT}"

GET_PIP="${BUILD_ROOT}/get-pip.py"

if [ ! -f "${GET_PIP}" ]; then
    curl -fL \
        https://bootstrap.pypa.io/pip/2.7/get-pip.py \
        -o "${GET_PIP}"
fi

run "${PYTHON}" "${GET_PIP}" \
    "pip==${PIP_VERSION}" \
    "setuptools==${SETUPTOOLS_VERSION}" \
    "wheel==${WHEEL_VERSION}"

###############################################################################
# 9. Install PADIT SERVER dependencies
###############################################################################

echo
echo "============================================================"
echo " Installing PADIT SERVER dependencies"
echo "============================================================"

SERVER_REQUIREMENTS="${BUILD_ROOT}/requirements-server-build.txt"
UJSON_REQUIREMENT_RE='^[[:space:]]*ujson==2\.0\.3([[:space:]]*(#.*)?)?$'

UJSON_REQ_COUNT="$(
    grep -Ec "${UJSON_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${UJSON_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one ujson==2.0.3 requirement, found ${UJSON_REQ_COUNT}"

grep -Ev "${UJSON_REQUIREMENT_RE}" \
    "${REPO_ROOT}/requirements-server.txt" \
    > "${SERVER_REQUIREMENTS}"

run "${PIP}" install \
    --no-cache-dir \
    -r "${SERVER_REQUIREMENTS}"

###############################################################################
# 10. Build ujson 2.0.3 with security backports
###############################################################################

echo
echo "============================================================"
echo " Building ujson 2.0.3 with security backports"
echo "============================================================"

UJSON_VERSION="2.0.3"
UJSON_BUILD_DIR="${BUILD_ROOT}/ujson-${UJSON_VERSION}-patched"

UJSON_PATCH_CVE_2022_31116="${REPO_ROOT}/utils/patch-ujson-2.0.3/CVE-2022-31116.patch"
UJSON_PATCH_CVE_2022_31116_SHA256="ccef883e16bbd8dad3b790f38ff2d324f5d0515a7e0d6f6377b86f509a6fb18d"

UJSON_PATCH_ISSUE_334="${REPO_ROOT}/utils/patch-ujson-2.0.3/issue-334-buffer-overflow.patch"
UJSON_PATCH_ISSUE_334_SHA256="1ddba061ddc6e776e518a5a272d6d7ca0263bac3b5ee947f554abc82795658fd"

for UJSON_PATCH in \
    "${UJSON_PATCH_CVE_2022_31116}" \
    "${UJSON_PATCH_ISSUE_334}"
do
    [ -f "${UJSON_PATCH}" ] \
        || die "ujson security patch not found: ${UJSON_PATCH}"
done

ACTUAL_UJSON_PATCH_SHA256="$(
    sha256sum "${UJSON_PATCH_CVE_2022_31116}" | awk '{print $1}'
)"

[ "${ACTUAL_UJSON_PATCH_SHA256}" = "${UJSON_PATCH_CVE_2022_31116_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2022-31116 patch: ${ACTUAL_UJSON_PATCH_SHA256}"

ACTUAL_UJSON_PATCH_SHA256="$(
    sha256sum "${UJSON_PATCH_ISSUE_334}" | awk '{print $1}'
)"

[ "${ACTUAL_UJSON_PATCH_SHA256}" = "${UJSON_PATCH_ISSUE_334_SHA256}" ] \
    || die "Unexpected SHA256 for issue 334 patch: ${ACTUAL_UJSON_PATCH_SHA256}"

rm -rf "${UJSON_BUILD_DIR}"
mkdir -p "${UJSON_BUILD_DIR}"
cd "${UJSON_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "ujson==${UJSON_VERSION}"

UJSON_SDIST="ujson-${UJSON_VERSION}.tar.gz"

[ -f "${UJSON_SDIST}" ] \
    || die "ujson source archive not found: ${UJSON_SDIST}"

tar -xf "${UJSON_SDIST}"

UJSON_SRC_DIR="${UJSON_BUILD_DIR}/ujson-${UJSON_VERSION}"

[ -d "${UJSON_SRC_DIR}" ] \
    || die "ujson source directory not found: ${UJSON_SRC_DIR}"

(
    cd "${UJSON_SRC_DIR}"

    for UJSON_PATCH in \
        "${UJSON_PATCH_CVE_2022_31116}" \
        "${UJSON_PATCH_ISSUE_334}"
    do
        patch --dry-run -p1 < "${UJSON_PATCH}" >/dev/null
        patch -p1 < "${UJSON_PATCH}"
    done
)

echo ">>> ujson CVE-2022-31116 backport applied."
echo ">>> ujson issue 334 buffer-overflow backport applied."

UJSON_WHEELHOUSE="${UJSON_BUILD_DIR}/wheelhouse"
mkdir -p "${UJSON_WHEELHOUSE}"

run "${PIP}" wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${UJSON_WHEELHOUSE}" \
    "${UJSON_SRC_DIR}"

run "${PIP}" install \
    --no-index \
    --no-deps \
    --find-links "${UJSON_WHEELHOUSE}" \
    "ujson==${UJSON_VERSION}"

UJSON_SRC_DIR="${UJSON_SRC_DIR}" "${PYTHON}" - <<'PYUJSON'
import json
import os
import ujson

expected_version = "2.0.3"
actual_version = ujson.__version__

if actual_version != expected_version:
    raise SystemExit(
        "Unexpected ujson version: %s (expected %s)"
        % (actual_version, expected_version)
    )

tests = [
    r'"\uD800"',
    r'"\uD800hello"',
    r'"\uDC00"',
    r'"\uD800foo bar\uDC00"',
    r'"\uD83D\uDCA9"',
]

for payload in tests:
    actual = ujson.loads(payload)
    expected = json.loads(payload)

    if actual != expected:
        raise AssertionError(
            "CVE-2022-31116 regression for %r: ujson=%r stdlib=%r"
            % (payload, actual, expected)
        )

reproducer = os.path.join(
    os.environ["UJSON_SRC_DIR"],
    "tests",
    "334-reproducer.json",
)

with open(reproducer, "rb") as f:
    issue_334_data = ujson.loads(f.read())

for indent in [0, 1, 2, 4, 5, 8, 49]:
    ujson.dumps(issue_334_data, indent=indent)

print(">>> ujson version verified: %s" % actual_version)
print("CVE-2022-31116 REGRESSION TEST: PASS")
print("ujson issue 334 REGRESSION TEST: PASS")
PYUJSON

echo ">>> ujson security backports verified."

###############################################################################
# 11. Apply urllib3 CVE-2026-97689 compatibility backport
###############################################################################

echo
echo "============================================================"
echo " Applying urllib3 CVE-2026-97689 backport"
echo "============================================================"

URLLIB3_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/urllib3"
URLLIB3_PATCH="${REPO_ROOT}/utils/patch-urllib3-1.26.20/CVE-2026-97689.patch"

[ -d "${URLLIB3_DIR}" ] \
    || die "urllib3 directory not found: ${URLLIB3_DIR}"

[ -f "${URLLIB3_PATCH}" ] \
    || die "urllib3 security patch not found: ${URLLIB3_PATCH}"

"${PYTHON}" - <<'PYURLLIB3'
import urllib3

expected = "1.26.20"
actual = urllib3.__version__

if actual != expected:
    raise SystemExit(
        "Unexpected urllib3 version: %s (expected %s)" % (actual, expected)
    )

print(">>> urllib3 version verified: %s" % actual)
PYURLLIB3

if grep -q '_MAX_CHUNK_LINE_LENGTH' "${URLLIB3_DIR}/response.py"; then
    echo ">>> urllib3 CVE-2026-97689 backport already present."
else
    (
        cd "${URLLIB3_DIR}"
        patch --dry-run -p1 < "${URLLIB3_PATCH}" >/dev/null
        patch -p1 < "${URLLIB3_PATCH}"
    )
    echo ">>> urllib3 CVE-2026-97689 backport applied."
fi

"${PYTHON}" -m py_compile "${URLLIB3_DIR}/response.py"

grep -q 'Response chunk size line exceeded maximum allowed length' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 chunk-size protection marker not found"

grep -q 'Response chunk trailer line exceeded maximum allowed length' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 trailer protection marker not found"

echo ">>> urllib3 CVE-2026-97689 backport verified."

###############################################################################
# 12. Apply urllib3 CVE-2025-66418 decompression-chain backport
###############################################################################

echo
echo "============================================================"
echo " Applying urllib3 CVE-2025-66418 backport"
echo "============================================================"

URLLIB3_PATCH_66418="${REPO_ROOT}/utils/patch-urllib3-1.26.20/CVE-2025-66418.patch"

[ -f "${URLLIB3_PATCH_66418}" ] \
    || die "urllib3 security patch not found: ${URLLIB3_PATCH_66418}"

if grep -q 'max_decode_links = 5' "${URLLIB3_DIR}/response.py"; then
    echo ">>> urllib3 CVE-2025-66418 backport already present."
else
    (
        cd "${URLLIB3_DIR}"
        patch --dry-run -p1 < "${URLLIB3_PATCH_66418}" >/dev/null
        patch -p1 < "${URLLIB3_PATCH_66418}"
    )
    echo ">>> urllib3 CVE-2025-66418 backport applied."
fi

"${PYTHON}" -m py_compile "${URLLIB3_DIR}/response.py"

grep -q 'max_decode_links = 5' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 decompression-chain limit marker not found"

grep -q 'Too many content encodings in the chain' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 decompression-chain rejection marker not found"

echo ">>> urllib3 CVE-2025-66418 backport verified."

###############################################################################
# 13. Apply urllib3 CVE-2025-66471 streaming decompression backport
###############################################################################

echo
echo "============================================================"
echo " Applying urllib3 CVE-2025-66471 backport"
echo "============================================================"

URLLIB3_PATCH_66471="${REPO_ROOT}/utils/patch-urllib3-1.26.20/CVE-2025-66471.patch"

[ -f "${URLLIB3_PATCH_66471}" ] \
    || die "urllib3 security patch not found: ${URLLIB3_PATCH_66471}"

if grep -q 'def decompress(self, data, max_length=-1)' \
    "${URLLIB3_DIR}/response.py" \
    && grep -q 'has_unconsumed_tail' \
    "${URLLIB3_DIR}/response.py"; then
    echo ">>> urllib3 CVE-2025-66471 backport already present."
else
    (
        cd "${URLLIB3_DIR}"
        patch --dry-run -p1 < "${URLLIB3_PATCH_66471}" >/dev/null
        patch -p1 < "${URLLIB3_PATCH_66471}"
    )
    echo ">>> urllib3 CVE-2025-66471 backport applied."
fi

"${PYTHON}" -m py_compile "${URLLIB3_DIR}/response.py"

grep -q 'def decompress(self, data, max_length=-1)' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 bounded decompression marker not found"

grep -q 'has_unconsumed_tail' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 unconsumed-tail marker not found"

grep -q 'max_length=amt' \
    "${URLLIB3_DIR}/response.py" \
    || die "urllib3 streaming decompression limit marker not found"

echo ">>> urllib3 CVE-2025-66471 backport verified."

###############################################################################
# 14. Apply requests CVE-2024-35195 TLS pool isolation backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2024-35195 backport"
echo "============================================================"

REQUESTS_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/requests"
REQUESTS_PATCH_35195="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2024-35195.patch"
REQUESTS_PATCH_35195_SHA256="4af162e6e503f464ae8a62fb208e89d4427f3349606014c2c22901f02a8451d8"

[ -d "${REQUESTS_DIR}" ] \
    || die "requests directory not found: ${REQUESTS_DIR}"

[ -f "${REQUESTS_PATCH_35195}" ] \
    || die "requests security patch not found: ${REQUESTS_PATCH_35195}"

REQUESTS_VERSION="$("${PYTHON}" -c 'import requests; print(requests.__version__)')"

[ "${REQUESTS_VERSION}" = "2.27.1" ] \
    || die "Unexpected requests version: ${REQUESTS_VERSION}"

echo ">>> requests version verified: ${REQUESTS_VERSION}"

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
# 15. Apply requests CVE-2024-47081 netrc hostname backport
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
# 16. Apply python-socketio CVE-2026-48804 backport
###############################################################################

echo
echo "============================================================"
echo " Applying python-socketio CVE-2026-48804 backport"
echo "============================================================"

SOCKETIO_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/socketio"
SOCKETIO_PATCH_48804="${REPO_ROOT}/utils/patch-python-socketio-4.4.0/CVE-2026-48804.patch"

[ -d "${SOCKETIO_DIR}" ] \
    || die "python-socketio directory not found: ${SOCKETIO_DIR}"

[ -f "${SOCKETIO_PATCH_48804}" ] \
    || die "python-socketio security patch not found: ${SOCKETIO_PATCH_48804}"

SOCKETIO_VERSION="$("${PYTHON}" -c 'import socketio; print(socketio.__version__)')"

[ "${SOCKETIO_VERSION}" = "4.4.0" ] \
    || die "Unexpected python-socketio version: ${SOCKETIO_VERSION}"

echo ">>> python-socketio version verified: ${SOCKETIO_VERSION}"

if grep -q "raise ValueError('Unexpected binary packet')" \
    "${SOCKETIO_DIR}/server.py" \
    && [ "$(grep -c 'if sid in self._binary_packet:' "${SOCKETIO_DIR}/server.py")" -ge 2 ]; then
    echo ">>> python-socketio CVE-2026-48804 backport already present."
else
    (
        cd "${SOCKETIO_DIR}"
        patch --dry-run -p1 < "${SOCKETIO_PATCH_48804}" >/dev/null
        patch -p1 < "${SOCKETIO_PATCH_48804}"
    )
    echo ">>> python-socketio CVE-2026-48804 backport applied."
fi

"${PYTHON}" -m py_compile "${SOCKETIO_DIR}/server.py"

grep -q "raise ValueError('Unexpected binary packet')" \
    "${SOCKETIO_DIR}/server.py" \
    || die "python-socketio unauthenticated binary rejection marker not found"

[ "$(grep -c 'if sid in self._binary_packet:' "${SOCKETIO_DIR}/server.py")" -ge 2 ] \
    || die "python-socketio binary disconnect cleanup markers not found"

echo ">>> Running CVE-2026-48804 regression test..."

"${PYTHON}" - <<'PYTEST'
import socketio

# Unknown/unconnected client must not allocate a partial binary packet.
s = socketio.Server(async_handlers=False)

try:
    s._handle_eio_message(
        '999',
        '52-["my message","a",'
        '{"_placeholder":true,"num":1},'
        '{"_placeholder":true,"num":0}]'
    )
except ValueError:
    pass
else:
    raise AssertionError("Unknown binary client was accepted")

assert '999' not in s._binary_packet

# Partial binary packet must disappear after Engine.IO disconnect.
s = socketio.Server(async_handlers=False)
s.manager.connect('123', '/')
s.environ['123'] = {}

s._handle_eio_message(
    '123',
    '52-["my message","a",'
    '{"_placeholder":true,"num":1},'
    '{"_placeholder":true,"num":0}]'
)

s._handle_eio_message('123', b'foo')

assert '123' in s._binary_packet

s._handle_eio_disconnect('123')

assert '123' not in s._binary_packet

print("CVE-2026-48804 REGRESSION TEST: PASS")
PYTEST

echo ">>> python-socketio CVE-2026-48804 backport verified."

###############################################################################
# 17. Verify critical packages
###############################################################################

echo
echo ">>> Verifying critical packages..."

"${PYTHON}" - <<'PY'
import sys

packages = [
    "flask",
    "flask_login",
    "flask_socketio",
    "eventlet",
    "greenlet",
    "cryptography",
    "OpenSSL",
    "requests",
    "peewee",
    "psutil",
    "netifaces",
    "ldap3",
    "psycopg2",
    "ujson",
]

failed = False

for module in packages:
    try:
        __import__(module)
        print("OK  ", module)
    except Exception as e:
        print("FAIL", module, ":", repr(e))
        failed = True

if failed:
    sys.exit(1)
PY

###############################################################################
# 18. Apply PADIT cryptography compatibility patch
###############################################################################

echo
echo "============================================================"
echo " Applying PADIT cryptography patch"
echo "============================================================"

CRYPTO_X509="${RUNTIME_ROOT}/lib/python2.7/site-packages/cryptography/x509"

[ -d "${CRYPTO_X509}" ] \
    || die "cryptography/x509 directory not found: ${CRYPTO_X509}"

cp -f \
    "${REPO_ROOT}/utils/patch-cryptography/__init__.py" \
    "${CRYPTO_X509}/__init__.py"

cp -f \
    "${REPO_ROOT}/utils/patch-cryptography/verification.py" \
    "${CRYPTO_X509}/verification.py"

echo ">>> PADIT cryptography patch installed."

###############################################################################
# 19. Apply PADIT socketIO client patch if present
###############################################################################

echo
echo "============================================================"
echo " Checking PADIT socketIO compatibility patch"
echo "============================================================"

SOCKETIO_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/socketIO_client"

if [ -d "${SOCKETIO_DIR}" ]; then

    echo ">>> socketIO_client found."

    cp -f \
        "${REPO_ROOT}/utils/patch-socketio-client-2/__init__.py" \
        "${SOCKETIO_DIR}/__init__.py"

    cp -f \
        "${REPO_ROOT}/utils/patch-socketio-client-2/transports.py" \
        "${SOCKETIO_DIR}/transports.py"

    echo ">>> PADIT socketIO patch installed."

else
    echo ">>> socketIO_client not installed."
    echo "    No socketIO-client-2 patch required for this server runtime."
fi

###############################################################################
# 20. Basic Python runtime validation
###############################################################################

echo
echo "============================================================"
echo " Python runtime validation"
echo "============================================================"

echo
echo ">>> Python:"
"${PYTHON}" --version

echo
echo ">>> Python executable:"
readlink -f "${PYTHON}"

echo
echo ">>> Python prefix:"
"${PYTHON}" -c \
    "import sys; print sys.prefix"

echo
echo ">>> Python OpenSSL:"
"${PYTHON}" -c \
    "import ssl; print ssl.OPENSSL_VERSION"

echo
echo ">>> pip:"
"${PIP}" --version

###############################################################################
# 21. PADIT server import validation
###############################################################################

echo
echo "============================================================"
echo " PADIT Server import validation"
echo "============================================================"

CONF_DIR="${RUNTIME_ROOT}/conf"
CONF_FILE="${CONF_DIR}/waptserver.ini"

mkdir -p "${CONF_DIR}"

cat > "${CONF_FILE}" <<'CONFIG'
[options]
wapt_bind_interface = 127.0.0.1
nginx_http = 80
nginx_https = 443
remote_repo_support = False
remote_repo_websockets = True
auto_create_ldap_users = True
wol_port = 9
enable_store = False
CONFIG

echo
echo ">>> Test configuration:"
cat "${CONF_FILE}"

echo
echo ">>> Importing PADIT server..."

CONFIG_FILE="${CONF_FILE}" \
PYTHONPATH="${REPO_ROOT}" \
"${PYTHON}" - <<'PY'
import waptserver.server

print("PADIT SERVER MODULE OK")
PY

###############################################################################
# 22. PADIT server component validation
###############################################################################

echo
echo ">>> Testing PADIT server components..."

CONFIG_FILE="${CONF_FILE}" \
PYTHONPATH="${REPO_ROOT}" \
"${PYTHON}" - <<'PY'
import waptserver.config
import waptserver.model
import waptserver.auth
import waptserver.tasks

print("PADIT SERVER COMPONENTS OK")
PY

###############################################################################
# 23. Socket.IO validation
###############################################################################

echo
echo ">>> Testing PADIT Socket.IO..."

CONFIG_FILE="${CONF_FILE}" \
PYTHONPATH="${REPO_ROOT}" \
"${PYTHON}" - <<'PY'
import waptserver.server_socketio

print("PADIT SOCKETIO OK")
PY

###############################################################################
# 24. PADIT crypto functional test
###############################################################################

echo
echo "============================================================"
echo " PADIT cryptographic functional test"
echo "============================================================"

CONFIG_FILE="${CONF_FILE}" \
PYTHONPATH="${REPO_ROOT}" \
"${PYTHON}" - <<'PY'
from waptcrypto import (
    SSLPrivateKey,
    SSLCertificate,
)

# CA
ca_key = SSLPrivateKey()
ca_key.create()

ca_cert = ca_key.build_sign_certificate(
    cn="WAPT Test CA",
    is_ca=True,

)

# Client
client_key = SSLPrivateKey()
client_key.create()

csr = client_key.build_csr(
    cn="WAPT Inventory Test Client"
)

client_cert = ca_cert.build_certificate_from_csr(
    csr,
    ca_key,

)

content = "WAPT inventory test"

signature = client_key.sign_content(content)

verified_cn = client_cert.verify_content(
    content,
    signature
)

print("Crypto verification:", verified_cn)

if verified_cn != "WAPT Inventory Test Client":
    raise Exception(
        "Unexpected certificate CN: %r" % verified_cn
    )

print("PADIT CRYPTO TEST PASSED")
PY

###############################################################################
# Remove temporary PADIT server test configuration
###############################################################################

echo
echo ">>> Removing temporary PADIT server test configuration"

rm -f "${CONF_FILE}"
rmdir "${CONF_DIR}" 2>/dev/null || true

if [ -e "${CONF_FILE}" ]; then
    echo "ERROR: temporary PADIT server configuration still present:"
    echo "  ${CONF_FILE}"
    exit 1
fi

###############################################################################
# 25. Generate runtime inventory
###############################################################################

echo
echo "============================================================"
echo " Runtime inventory"
echo "============================================================"

INVENTORY="${RUNTIME_ROOT}/WAPT-runtime-inventory.txt"

{
    echo "===== PADIT PYTHON 2 RUNTIME ====="
    echo
    echo "Build date:"
    date -u
    echo
    echo "Repository:"
    git -C "${REPO_ROOT}" rev-parse --show-toplevel
    echo
    echo "Git commit:"
    git -C "${REPO_ROOT}" rev-parse HEAD
    echo
    echo "Git branch:"
    git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD
    echo
    echo "===== SYSTEM ====="
    cat /etc/debian_version
    uname -a
    echo
    echo "===== COMPILER ====="
    gcc --version | head -n 1
    echo
    echo "===== PYTHON ====="
    "${PYTHON}" --version
    "${PYTHON}" -c "import sys; print sys.prefix"
    echo
    echo "===== OPENSSL ====="
    "${PYTHON}" -c "import ssl; print ssl.OPENSSL_VERSION"
    echo
    echo "===== PIP ====="
    "${PIP}" --version
    echo
    echo "===== PACKAGES ====="
    "${PIP}" freeze
    echo
    echo "===== SIZE ====="
    du -sh "${RUNTIME_ROOT}"
    echo
    echo "===== PYTHON BINARY SHA256 ====="
    sha256sum "${PYTHON}"
} > "${INVENTORY}"

echo
echo ">>> Runtime inventory:"
cat "${INVENTORY}"

###############################################################################
# 26. Final status
###############################################################################

echo
echo "============================================================"
echo " BUILD SUCCESS"
echo "============================================================"

echo
echo "Runtime:"
echo "  ${RUNTIME_ROOT}"

echo
echo "Python:"
echo "  ${PYTHON}"

echo
echo "Inventory:"
echo "  ${INVENTORY}"

echo
echo "IMPORTANT:"
echo "  This is a transitional Python 2 compatibility runtime."
echo "  Do NOT expose it as the final security architecture."

echo
echo "All PADIT runtime tests passed."
echo
