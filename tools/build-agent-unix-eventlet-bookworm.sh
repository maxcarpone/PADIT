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

# 27. Apply eventlet CVE-2025-58068 trailer parsing backport
###############################################################################

echo
echo "============================================================"
echo " Applying eventlet CVE-2025-58068 backport"
echo "============================================================"

EVENTLET_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/eventlet"
EVENTLET_PATCH_58068="${REPO_ROOT}/utils/patch-eventlet-0.33.3/CVE-2025-58068.patch"
EVENTLET_PATCH_58068_SHA256="897e91e4e5c77fe8205408e4daca9c9fc12da7540f34f2c19f92875343ea151d"

[ -d "${EVENTLET_DIR}" ] \
    || die "eventlet directory not found: ${EVENTLET_DIR}"

[ -f "${EVENTLET_PATCH_58068}" ] \
    || die "eventlet CVE-2025-58068 patch not found: ${EVENTLET_PATCH_58068}"

EVENTLET_VERSION="$("${PYTHON}" -c 'import eventlet; print(eventlet.__version__)')"

[ "${EVENTLET_VERSION}" = "0.33.3" ] \
    || die "Unexpected eventlet version: ${EVENTLET_VERSION}"

echo ">>> eventlet version verified: ${EVENTLET_VERSION}"

ACTUAL_EVENTLET_PATCH_58068_SHA256="$(
    sha256sum "${EVENTLET_PATCH_58068}" | awk '{print $1}'
)"

[ "${ACTUAL_EVENTLET_PATCH_58068_SHA256}" = "${EVENTLET_PATCH_58068_SHA256}" ] \
    || die "Unexpected SHA256 for eventlet CVE-2025-58068 patch: ${ACTUAL_EVENTLET_PATCH_58068_SHA256}"

if grep -q 'def _discard_trailers(self, rfile):' \
    "${EVENTLET_DIR}/wsgi.py"; then
    echo ">>> eventlet CVE-2025-58068 backport already present."
else
    (
        cd "${EVENTLET_DIR}"
        patch --dry-run -p1 < "${EVENTLET_PATCH_58068}" >/dev/null
        patch -p1 < "${EVENTLET_PATCH_58068}"
    )
    echo ">>> eventlet CVE-2025-58068 backport applied."
fi

"${PYTHON}" -m py_compile "${EVENTLET_DIR}/wsgi.py"

echo ">>> Running CVE-2025-58068 regression test..."

"${PYTHON}" - <<'PYTEST'
from io import BytesIO
from eventlet.wsgi import Input

raw = (
    b"0\r\n"
    b"X-Trailer-One: one\r\n"
    b"X-Trailer-Two: two\r\n"
    b"\r\n"
    b"GET /next HTTP/1.1\r\n"
)

rfile = BytesIO(raw)

inp = Input(
    rfile=rfile,
    content_length=None,
    sock=None,
    chunked_input=True,
)

body = inp.read()
remaining = rfile.readline()

assert body == b""
assert remaining == b"GET /next HTTP/1.1\r\n"

print("CVE-2025-58068 TRAILER DISCARD TEST: PASS")
PYTEST

echo ">>> eventlet CVE-2025-58068 backport verified."

###############################################################################
# 28. Apply Eventlet/dnspython CVE-2023-29483 TuDoor backport
###############################################################################

echo
echo "============================================================"
echo " Applying Eventlet/dnspython CVE-2023-29483 backport"
echo "============================================================"

EVENTLET_PATCH_29483="${REPO_ROOT}/utils/patch-eventlet-0.33.3/CVE-2023-29483.patch"
EVENTLET_PATCH_29483_SHA256="cfb887610c8229a14d595921b1fd79d0ecc2997ec74dd6a1a220978e9f7a5ad1"

DNSPYTHON_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/dns"
DNSPYTHON_PATCH_29483="${REPO_ROOT}/utils/patch-dnspython-1.16.0/CVE-2023-29483.patch"
DNSPYTHON_PATCH_29483_SHA256="f87ca8bc3c3608ebd8cb84a5ede045ea243d1f69d07ffaccc6873f70b5502e84"

[ -d "${EVENTLET_DIR}" ] \
    || die "eventlet directory not found: ${EVENTLET_DIR}"

[ -d "${DNSPYTHON_DIR}" ] \
    || die "dnspython directory not found: ${DNSPYTHON_DIR}"

[ -f "${EVENTLET_PATCH_29483}" ] \
    || die "eventlet CVE-2023-29483 patch not found: ${EVENTLET_PATCH_29483}"

[ -f "${DNSPYTHON_PATCH_29483}" ] \
    || die "dnspython CVE-2023-29483 patch not found: ${DNSPYTHON_PATCH_29483}"

EVENTLET_VERSION="$("${PYTHON}" -c 'import eventlet; print(eventlet.__version__)')"
DNSPYTHON_VERSION="$("${PYTHON}" -c 'import pkg_resources; print(pkg_resources.get_distribution("dnspython").version)')"

[ "${EVENTLET_VERSION}" = "0.33.3" ] \
    || die "Unexpected eventlet version: ${EVENTLET_VERSION}"

[ "${DNSPYTHON_VERSION}" = "1.16.0" ] \
    || die "Unexpected dnspython version: ${DNSPYTHON_VERSION}"

echo ">>> eventlet version verified: ${EVENTLET_VERSION}"
echo ">>> dnspython version verified: ${DNSPYTHON_VERSION}"

ACTUAL_EVENTLET_PATCH_29483_SHA256="$(
    sha256sum "${EVENTLET_PATCH_29483}" | awk '{print $1}'
)"

[ "${ACTUAL_EVENTLET_PATCH_29483_SHA256}" = "${EVENTLET_PATCH_29483_SHA256}" ] \
    || die "Unexpected SHA256 for eventlet CVE-2023-29483 patch: ${ACTUAL_EVENTLET_PATCH_29483_SHA256}"

ACTUAL_DNSPYTHON_PATCH_29483_SHA256="$(
    sha256sum "${DNSPYTHON_PATCH_29483}" | awk '{print $1}'
)"

[ "${ACTUAL_DNSPYTHON_PATCH_29483_SHA256}" = "${DNSPYTHON_PATCH_29483_SHA256}" ] \
    || die "Unexpected SHA256 for dnspython CVE-2023-29483 patch: ${ACTUAL_DNSPYTHON_PATCH_29483_SHA256}"

if grep -q 'sock=None, ignore_errors=False):' \
    "${EVENTLET_DIR}/support/greendns.py"; then
    echo ">>> eventlet CVE-2023-29483 backport already present."
else
    (
        cd "${EVENTLET_DIR}"
        patch --dry-run -p1 < "${EVENTLET_PATCH_29483}" >/dev/null
        patch -p1 < "${EVENTLET_PATCH_29483}"
    )
    echo ">>> eventlet CVE-2023-29483 backport applied."
fi

if grep -q 'ignore_errors=False' "${DNSPYTHON_DIR}/query.py" \
    && grep -A6 'response = dns.query.udp' "${DNSPYTHON_DIR}/resolver.py" \
       | grep -q 'ignore_errors=True'; then
    echo ">>> dnspython CVE-2023-29483 backport already present."
else
    (
        cd "${DNSPYTHON_DIR}"
        patch --dry-run -p1 < "${DNSPYTHON_PATCH_29483}" >/dev/null
        patch -p1 < "${DNSPYTHON_PATCH_29483}"
    )
    echo ">>> dnspython CVE-2023-29483 backport applied."
fi

"${PYTHON}" -m py_compile \
    "${EVENTLET_DIR}/support/greendns.py" \
    "${DNSPYTHON_DIR}/query.py" \
    "${DNSPYTHON_DIR}/resolver.py"

grep -q 'sock=None, ignore_errors=False):' \
    "${EVENTLET_DIR}/support/greendns.py" \
    || die "eventlet CVE-2023-29483 ignore_errors marker not found"

grep -q 'ignore_errors=False' "${DNSPYTHON_DIR}/query.py" \
    || die "dnspython CVE-2023-29483 query API marker not found"

grep -A6 'response = dns.query.udp' "${DNSPYTHON_DIR}/resolver.py" \
    | grep -q 'ignore_errors=True' \
    || die "dnspython CVE-2023-29483 resolver marker not found"

echo ">>> Running CVE-2023-29483 dnspython standalone regression test..."

"${PYTHON}" - <<'PYTEST'
import dns.exception
import dns.message
import dns.query


class FakeResponse(object):
    def __init__(self):
        self.time = None


class FakeQuery(object):
    keyring = None
    mac = b''

    def to_wire(self):
        return b'QUERY'

    def is_response(self, response):
        return isinstance(response, FakeResponse)


class FakeSocket(object):
    family = 2

    def __init__(self):
        self.responses = [
            (b'BAD_PACKET', ('127.0.0.1', 53)),
            (b'GOOD_PACKET', ('127.0.0.1', 53)),
        ]
        self.recv_count = 0

    def setblocking(self, value):
        pass

    def bind(self, source):
        pass

    def sendto(self, wire, destination):
        return len(wire)

    def recvfrom(self, size):
        self.recv_count += 1
        return self.responses.pop(0)

    def close(self):
        pass


real_socket_factory = dns.query.socket_factory
real_wait_readable = dns.query._wait_for_readable
real_wait_writable = dns.query._wait_for_writable
real_from_wire = dns.message.from_wire

sock = FakeSocket()


def fake_socket_factory(af, socktype, proto):
    return sock


def fake_wait(sock, expiration):
    return None


def fake_from_wire(wire, *args, **kwargs):
    if wire == b'BAD_PACKET':
        raise dns.exception.FormError('malformed spoofed response')
    if wire == b'GOOD_PACKET':
        return FakeResponse()
    raise AssertionError('Unexpected packet: %r' % (wire,))


dns.query.socket_factory = fake_socket_factory
dns.query._wait_for_readable = fake_wait
dns.query._wait_for_writable = fake_wait
dns.message.from_wire = fake_from_wire

try:
    result = dns.query.udp(
        FakeQuery(),
        '127.0.0.1',
        timeout=1,
        port=53,
        ignore_errors=True,
    )

    assert isinstance(result, FakeResponse)
    assert sock.recv_count == 2
    assert result.time >= 0

    print("CVE-2023-29483 DNSPYTHON STANDALONE REGRESSION: PASS")
finally:
    dns.query.socket_factory = real_socket_factory
    dns.query._wait_for_readable = real_wait_readable
    dns.query._wait_for_writable = real_wait_writable
    dns.message.from_wire = real_from_wire
PYTEST

echo ">>> Running CVE-2023-29483 post-fix regression test..."

"${PYTHON}" - <<'PYTEST'
import dns
import dns.exception
import dns.inet
import dns.message

from eventlet.support import greendns


class FakeQuery(object):
    keyring = None
    mac = b''

    def to_wire(self):
        return b'QUERY'

    def is_response(self, response):
        return response == 'VALID_RESPONSE'


class FakeSocket(object):
    def __init__(self):
        self.responses = [
            (b'BAD_PACKET', ('127.0.0.1', 53)),
            (b'GOOD_PACKET', ('127.0.0.1', 53)),
        ]
        self.recv_count = 0

    def settimeout(self, timeout):
        pass

    def sendto(self, wire, destination):
        return len(wire)

    def recvfrom(self, size):
        self.recv_count += 1
        return self.responses.pop(0)

    def close(self):
        pass


real_from_wire = dns.message.from_wire


def fake_from_wire(wire, *args, **kwargs):
    if wire == b'BAD_PACKET':
        raise dns.exception.FormError('malformed spoofed response')
    if wire == b'GOOD_PACKET':
        return 'VALID_RESPONSE'
    raise AssertionError('Unexpected packet: %r' % (wire,))


dns.message.from_wire = fake_from_wire

try:
    sock = FakeSocket()

    result = greendns.udp(
        FakeQuery(),
        '127.0.0.1',
        timeout=1,
        port=53,
        af=dns.inet.AF_INET,
        sock=sock,
        ignore_errors=True,
    )

    assert result == 'VALID_RESPONSE'
    assert sock.recv_count == 2

    print("CVE-2023-29483 POST-FIX REGRESSION: PASS")
finally:
    dns.message.from_wire = real_from_wire
PYTEST

echo ">>> Running CVE-2023-29483 direct UDP compatibility test..."

"${PYTHON}" - <<'PYTEST'
import dns
import dns.exception
import dns.inet
import dns.message

from eventlet.support import greendns


class FakeQuery(object):
    keyring = None
    mac = b''

    def to_wire(self):
        return b'QUERY'

    def is_response(self, response):
        return response == 'VALID_RESPONSE'


class FakeSocket(object):
    def __init__(self):
        self.responses = [
            (b'BAD_PACKET', ('127.0.0.1', 53)),
            (b'GOOD_PACKET', ('127.0.0.1', 53)),
        ]
        self.recv_count = 0

    def settimeout(self, timeout):
        pass

    def sendto(self, wire, destination):
        return len(wire)

    def recvfrom(self, size):
        self.recv_count += 1
        return self.responses.pop(0)

    def close(self):
        pass


real_from_wire = dns.message.from_wire


def fake_from_wire(wire, *args, **kwargs):
    if wire == b'BAD_PACKET':
        raise dns.exception.FormError('malformed spoofed response')
    if wire == b'GOOD_PACKET':
        return 'VALID_RESPONSE'
    raise AssertionError('Unexpected packet: %r' % (wire,))


dns.message.from_wire = fake_from_wire
sock = FakeSocket()

try:
    try:
        greendns.udp(
            FakeQuery(),
            '127.0.0.1',
            timeout=1,
            port=53,
            af=dns.inet.AF_INET,
            sock=sock,
            ignore_errors=False,
        )
    except dns.exception.FormError:
        assert sock.recv_count == 1
        print("CVE-2023-29483 DIRECT UDP COMPATIBILITY: PASS")
    else:
        raise AssertionError("Expected FormError was not raised")
finally:
    dns.message.from_wire = real_from_wire
PYTEST

echo ">>> Eventlet/dnspython CVE-2023-29483 backport verified."

###############################################################################

echo "[PASS] Agent Unix Eventlet security backports"
