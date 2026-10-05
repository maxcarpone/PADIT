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

run "${PIP}" install \
    --no-cache-dir \
    -r "${REPO_ROOT}/requirements-server.txt"

###############################################################################
# 10. Apply urllib3 CVE-2026-97689 compatibility backport
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
# 11. Apply urllib3 CVE-2025-66418 decompression-chain backport
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
# 12. Apply urllib3 CVE-2025-66471 streaming decompression backport
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
# 13. Verify critical packages
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
# 14. Apply PADIT cryptography compatibility patch
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
# 15. Apply PADIT socketIO client patch if present
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
# 16. Basic Python runtime validation
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
# 17. PADIT server import validation
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
# 18. PADIT server component validation
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
# 19. Socket.IO validation
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
# 20. PADIT crypto functional test
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
# 21. Generate runtime inventory
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
# 22. Final status
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
