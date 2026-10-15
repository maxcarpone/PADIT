#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${PADIT_AGENT_UNIX_RUNTIME_ROOT:-${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm}"
PYTHON="${RUNTIME_ROOT}/bin/python"
PATCH_DIR="${REPO_ROOT}/utils/patch-python-ldap-3.3.1"
TEST="${REPO_ROOT}/utils/test-agent-unix-python-ldap.py"

VERSION="3.3.1"
ARCHIVE="python-ldap-3.3.1.tar.gz"
SHA256="4711cacf013e298754abd70058ccc995758177fb425f1c2d30e71adfc1d00aa5"
URL="https://files.pythonhosted.org/packages/9d/e2/deb47064d443344b708ffb5899ea269b201d7c22dcc653ebadcbb44c57d5/python-ldap-3.3.1.tar.gz"

MODE="${1:-install}"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

case "${MODE}" in
    install|--build-only) ;;
    *) die "Usage: $0 [--build-only]" ;;
esac

[ -x "${PYTHON}" ] || die "Python agent Unix absent"
[ -f "${TEST}" ] || die "Tests LDAP absents"

"${PYTHON}" -c \
    'import sys; assert sys.version_info[:3] == (2,7,18)' \
    || die "Python 2.7.18 requis"

WORK="$(mktemp -d /tmp/padit-agent-unix-ldap-XXXXXXXX)"
[ -d "${WORK}" ] || die "Creation du repertoire temporaire impossible"

echo ">>> PADIT python-ldap ${VERSION} / mode ${MODE}"
echo "Work: ${WORK}"

cd "${WORK}"

curl -fL --retry 3 "${URL}" -o "${ARCHIVE}"

echo "${SHA256}  ${ARCHIVE}" | sha256sum -c - \
    || die "Archive python-ldap invalide"

tar -xzf "${ARCHIVE}"

SOURCE="${WORK}/python-ldap-3.3.1"
[ -d "${SOURCE}" ] || die "Sources LDAP absentes"

cd "${SOURCE}"

PATCHES=(
    'CVE-2021-46823-ReDoS.patch:9c054a678d27ad2fac4d8184d1b6fc1699ebef9e1a862d2c99c6d238c26fa3b4'
    'CVE-2025-61911.patch:0051cdca6b7d6978307b933589e5b961d38b0bf5d5d75a1eb265dc4916a64302'
    'CVE-2025-61912.patch:ccaa8e5780a38d7586907c9408e06453efa49f96ac762952bf025845e9ddc777'
)

for ITEM in "${PATCHES[@]}"; do
    NAME="${ITEM%%:*}"
    HASH="${ITEM#*:}"
    FILE="${PATCH_DIR}/${NAME}"

    [ -f "${FILE}" ] || die "Patch absent : ${NAME}"

    echo "${HASH}  ${FILE}" | sha256sum -c - \
        || die "SHA256 invalide : ${NAME}"

    patch --batch --forward --dry-run -p1 < "${FILE}"
    patch --batch --forward -p1 < "${FILE}"

    echo "[PASS] Patch ${NAME}"
done

echo ">>> Tests de securite sur les sources corrigees"

"${PYTHON}" "${TEST}" "${SOURCE}/Lib/ldap"

echo ">>> Construction du wheel natif"

mkdir -p "${WORK}/wheelhouse"

"${PYTHON}" -m pip wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${WORK}/wheelhouse" \
    "${SOURCE}"

WHEEL="${WORK}/wheelhouse/python_ldap-${VERSION}-cp27-cp27mu-linux_x86_64.whl"

[ -f "${WHEEL}" ] || die "Wheel natif attendu absent : ${WHEEL}"

echo "[PASS] Wheel natif construit : ${WHEEL}"

if [ "${MODE}" = "--build-only" ]; then
    echo "[PASS] python-ldap ${VERSION} corrige / build-only"
    echo "Wheel: ${WHEEL}"
else
    echo ">>> Installation du wheel corrige"

    "${PYTHON}" -m pip install \
        --force-reinstall \
        --no-deps \
        --no-index \
        "${WHEEL}"

    "${PYTHON}" - <<'PY'
# -*- coding: utf-8 -*-
from __future__ import print_function
import os
import sys
import ldap
import _ldap
import ldap.filter
import ldap.dn
import ldap.schema.tokenizer

runtime = os.path.realpath(sys.prefix)

assert ldap.__version__ == '3.3.1'
assert _ldap.__version__ == '3.3.1'

for module in (ldap, _ldap, ldap.filter, ldap.dn, ldap.schema.tokenizer):
    path = os.path.realpath(module.__file__)
    assert path.startswith(runtime + os.sep), (module.__name__, path)

assert ldap.filter.escape_filter_chars('a*b') == r'a\2ab'
assert ldap.dn.escape_dn_chars('a\x00b') == r'a\00b'
assert ldap.schema.tokenizer.split_tokens("( NAME 'example' )") == [
    '(', 'NAME', 'example', ')'
]

print('[PASS] python-ldap 3.3.1 native et correctifs installes')
PY

    SITE="$("${PYTHON}" -c \
        'from distutils.sysconfig import get_python_lib; print(get_python_lib())')"

    "${PYTHON}" "${TEST}" "${SITE}/ldap"

    echo "[PASS] python-ldap ${VERSION} securise et installe"
fi
