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

# 30. Apply pyOpenSSL CVE-2026-27448 SNI callback backport
###############################################################################

echo
echo ">>> Applying pyOpenSSL CVE-2026-27448 security backport..."

PYOPENSSL_PATCH="${REPO_ROOT}/utils/patch-pyopenssl-19.0.0/CVE-2026-27448.patch"
PYOPENSSL_PATCH_SHA256="30aa14431d2f886ab8a4caf421c8e4811938fd7b1c32d98ec5e9ffcccad171d0"
PYOPENSSL_TEST="${REPO_ROOT}/utils/patch-pyopenssl-19.0.0/test-CVE-2026-27448.py"
PYOPENSSL_SITE="${RUNTIME_ROOT}/lib/python2.7/site-packages"

[ -f "${PYOPENSSL_PATCH}" ] || die "pyOpenSSL security patch missing"
[ -f "${PYOPENSSL_TEST}" ] || die "pyOpenSSL regression test missing"
[ -f "${PYOPENSSL_SITE}/OpenSSL/SSL.py" ] || die "pyOpenSSL SSL.py missing"

ACTUAL_PYOPENSSL_SHA256="$(
    sha256sum "${PYOPENSSL_PATCH}" | awk '{print $1}'
)"

[ "${ACTUAL_PYOPENSSL_SHA256}" = "${PYOPENSSL_PATCH_SHA256}" ] \
    || die "Unexpected SHA256 for pyOpenSSL security patch"

(
    cd "${PYOPENSSL_SITE}"
    patch --dry-run --fuzz=0 -p1 < "${PYOPENSSL_PATCH}" >/dev/null \
        || die "pyOpenSSL patch dry-run failed"
    patch --fuzz=0 -p1 < "${PYOPENSSL_PATCH}" \
        || die "pyOpenSSL patch application failed"
)

echo ">>> pyOpenSSL security patch applied."

env -u PYTHONPATH PADIT_EXPECTED_RUNTIME="${RUNTIME_ROOT}" "${PYTHON}" "${PYOPENSSL_TEST}" \
    || die "pyOpenSSL CVE-2026-27448 regression test failed"

echo ">>> pyOpenSSL CVE-2026-27448 regression verified."

###############################################################################

echo "[PASS] build-agent-unix-pyopenssl-bookworm.sh"
