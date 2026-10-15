#!/bin/bash
set -euo pipefail

# PADIT - Agent Unix Python 2.7.18 runtime
# Debian 12 Bookworm - isolated compatibility build

PYTHON_VERSION="2.7.18"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PADIT_AGENT_UNIX_BUILD_ROOT:-/tmp/padit-python2-agent-unix-bookworm-build}"
RUNTIME_ROOT="${PADIT_AGENT_UNIX_RUNTIME_ROOT:-${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm}"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Root privileges required"
[ -f "${REPO_ROOT}/requirements-agent.txt" ] || die "Missing common requirements"
[ -f "${REPO_ROOT}/requirements-agent-unix.txt" ] || die "Missing Unix requirements"

[ ! -e "${RUNTIME_ROOT}" ] || die "Runtime already exists: ${RUNTIME_ROOT}"

echo "[PASS] Agent Unix runtime preflight"
echo "Repository: ${REPO_ROOT}"
echo "Build root: ${BUILD_ROOT}"
echo "Runtime: ${RUNTIME_ROOT}"
echo "Python: ${PYTHON_VERSION}"


# Python 2.7.18 - isolated agent build
ARCHIVE="Python-${PYTHON_VERSION}.tgz"
SOURCE_ARCHIVE="/tmp/wapt-python2-build/${ARCHIVE}"
EXPECTED_SHA256="da3080e3b488f648a3d7a4560ddee895284c3380b11d6de75edb986526b9a814"
SOURCE_DIR="${BUILD_ROOT}/Python-${PYTHON_VERSION}"

[ ! -e "${BUILD_ROOT}" ] || die "Build directory already exists: ${BUILD_ROOT}"
mkdir -p "${BUILD_ROOT}"

if [ -f "${SOURCE_ARCHIVE}" ]; then
    cp "${SOURCE_ARCHIVE}" "${BUILD_ROOT}/${ARCHIVE}"
else
    curl -fL --retry 3 \
        "https://www.python.org/ftp/python/${PYTHON_VERSION}/${ARCHIVE}" \
        -o "${BUILD_ROOT}/${ARCHIVE}"
fi

echo "${EXPECTED_SHA256}  ${BUILD_ROOT}/${ARCHIVE}" | sha256sum -c - \
    || die "Python source checksum mismatch"

tar -xzf "${BUILD_ROOT}/${ARCHIVE}" -C "${BUILD_ROOT}"

cd "${SOURCE_DIR}"

./configure \
    --prefix="${RUNTIME_ROOT}" \
    --enable-unicode=ucs4 \
    --with-ensurepip=no

make -j"$(nproc)"
make install

"${RUNTIME_ROOT}/bin/python" -c \
    'import sys, ssl, sqlite3, zlib, bz2, ctypes; assert sys.version_info[:3] == (2,7,18); print("[PASS] Agent Unix CPython 2.7.18")'

echo "[PASS] U10 - Python agent Unix compiled"

echo ">>> Installing Python 2 packaging tools..."

GET_PIP="${BUILD_ROOT}/get-pip.py"
EXISTING_GET_PIP="/tmp/wapt-python2-build/get-pip.py"

if [ -f "${EXISTING_GET_PIP}" ]; then
    cp "${EXISTING_GET_PIP}" "${GET_PIP}"
else
    curl -fL --retry 3 \
        https://bootstrap.pypa.io/pip/2.7/get-pip.py \
        -o "${GET_PIP}"
fi

"${RUNTIME_ROOT}/bin/python" "${GET_PIP}" \
    'pip==20.3.4' \
    'setuptools==44.1.1' \
    'wheel==0.34.2'

"${RUNTIME_ROOT}/bin/python" -c \
    'import pip, setuptools, wheel; assert pip.__version__ == "20.3.4"; assert setuptools.__version__ == "44.1.1"; assert wheel.__version__ == "0.34.2"; print("[PASS] U11 - Packaging Python 2 agent Unix")'

echo ">>> Preparing Unix requirements without unpatched python-ldap..."

UNIX_REQUIREMENTS="${BUILD_ROOT}/requirements-agent-unix-initial.txt"

python3 - "${REPO_ROOT}/requirements-agent-unix.txt" "${UNIX_REQUIREMENTS}" <<'PYLDAPREQ'
import sys

source, destination = sys.argv[1:3]

with open(source, 'rb') as handle:
    data = handle.read()

lines = data.replace(b'\r\n', b'\n').splitlines()

expected = b'python-ldap==3.3.1'

if lines.count(expected) != 1:
    raise SystemExit('[FAIL] Expected exactly one python-ldap 3.3.1 pin')

remaining = [line for line in lines if line != expected]

if any(line.lower().lstrip().startswith(b'python-ldap') for line in remaining):
    raise SystemExit('[FAIL] Unexpected python-ldap requirement')

with open(destination, 'wb') as handle:
    handle.write(b'\n'.join(remaining) + b'\n')

print('[PASS] Unix requirements normalized; unpatched LDAP excluded')
PYLDAPREQ

echo ">>> Installing common and Unix agent dependencies..."

"${RUNTIME_ROOT}/bin/python" -m pip install \
    --no-cache-dir \
    -r "${REPO_ROOT}/requirements-agent.txt" \
    -r "${UNIX_REQUIREMENTS}"

echo "[PASS] Initial agent Unix dependencies installed"

echo ">>> Verifying python-ldap was not installed transitively..."

"${RUNTIME_ROOT}/bin/python" - <<'PYLDAPABSENT'
import pkg_resources

installed = [
    d for d in pkg_resources.working_set
    if d.key == 'python-ldap'
]

assert not installed, 'Unpatched python-ldap installed: %r' % installed
print('[PASS] No unpatched python-ldap distribution installed')
PYLDAPABSENT

echo ">>> Building secured python-ldap 3.3.1..."
bash "${REPO_ROOT}/tools/build-agent-unix-python-ldap-bookworm.sh"

echo "[PASS] Secured python-ldap installed"

echo ">>> Building patched Flask..."
bash "${REPO_ROOT}/tools/build-agent-unix-flask-bookworm.sh"

echo ">>> Building patched Jinja2..."
bash "${REPO_ROOT}/tools/build-agent-unix-jinja2-bookworm.sh"

echo ">>> Applying python-socketio security backport..."
bash "${REPO_ROOT}/tools/build-agent-unix-socketio-bookworm.sh"

echo ">>> Applying pyOpenSSL security backport..."
bash "${REPO_ROOT}/tools/build-agent-unix-pyopenssl-bookworm.sh"

echo ">>> Applying Eventlet and dnspython security backports..."
bash "${REPO_ROOT}/tools/build-agent-unix-eventlet-bookworm.sh"

echo ">>> Applying Werkzeug security backports..."
bash "${REPO_ROOT}/tools/build-agent-unix-werkzeug-bookworm.sh"

echo ">>> Applying Requests security backports..."
bash "${REPO_ROOT}/tools/build-agent-unix-requests-bookworm.sh"

echo ">>> Building patched cffi and cryptography..."
bash "${REPO_ROOT}/tools/build-agent-unix-crypto-bookworm.sh"

echo ">>> Building patched ujson for Unix agent..."
bash "${REPO_ROOT}/tools/build-agent-unix-ujson-bookworm.sh"

echo ">>> Building patched urllib3 for Unix agent..."
bash "${REPO_ROOT}/tools/build-agent-unix-urllib3-bookworm.sh"

echo ">>> Final verification of secured python-ldap..."

"${RUNTIME_ROOT}/bin/python" - <<'PYLDAPFINAL'
import os
import sys
import pkg_resources
import ldap
import _ldap
import ldap.filter
import ldap.dn
import ldap.schema.tokenizer

distribution = pkg_resources.get_distribution('python-ldap')
assert distribution.version == '3.3.1', distribution.version
assert ldap.__version__ == '3.3.1'
assert _ldap.__version__ == '3.3.1'

runtime = os.path.realpath(sys.prefix)
for module in (ldap, _ldap, ldap.filter, ldap.dn, ldap.schema.tokenizer):
    location = os.path.realpath(module.__file__)
    assert location.startswith(runtime + os.sep), location

assert ldap.filter.escape_filter_chars('a*b') == r'a\2ab'
assert ldap.dn.escape_dn_chars('a\x00b') == r'a\00b'
assert ldap.schema.tokenizer.split_tokens("( NAME 'example' )") == [
    '(', 'NAME', 'example', ')'
]

print('[PASS] Final python-ldap 3.3.1 native and security verification')
PYLDAPFINAL

LDAP_SITE="$("${RUNTIME_ROOT}/bin/python" -c \
    'from distutils.sysconfig import get_python_lib; print(get_python_lib())')"

"${RUNTIME_ROOT}/bin/python" \
    "${REPO_ROOT}/utils/test-agent-unix-python-ldap.py" \
    "${LDAP_SITE}/ldap"

echo "[PASS] Agent Unix python-ldap security verification completed"
