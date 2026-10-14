#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm"
PYTHON="${RUNTIME_ROOT}/bin/python"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

[ -x "${PYTHON}" ] || die "Agent Python missing"

# 29. Apply python-socketio CVE-2026-48804 backport
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

echo "[PASS] build-agent-unix-socketio-bookworm.sh"
