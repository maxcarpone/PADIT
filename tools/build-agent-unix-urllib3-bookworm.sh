#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm/bin/python"
PATCH_DIR="${REPO_ROOT}/utils/patch-urllib3-1.26.20"
WORK="$(mktemp -d /tmp/padit-agent-unix-urllib3-XXXXXXXX)"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

[ -x "${PYTHON}" ] || die "Agent runtime missing"
[ ! -e "${WORK}" ] || die "Work directory already exists: ${WORK}"

mkdir -p "${WORK}"

"${PYTHON}" -m pip download \
    --no-deps --no-binary=:all: \
    --dest "${WORK}" 'urllib3==1.26.20'

echo '40c2dc0c681e47eb8f90e7e27bf6ff7df2e677421fd46756da1161c39ca70d32  '"${WORK}/urllib3-1.26.20.tar.gz" \
    | sha256sum -c -

tar -xzf "${WORK}/urllib3-1.26.20.tar.gz" -C "${WORK}"

SOURCE="${WORK}/urllib3-1.26.20"
PACKAGE="${SOURCE}/src/urllib3"
[ -f "${PACKAGE}/response.py" ] || die "Invalid urllib3 source"

cd "${PACKAGE}"

PATCHES=(
    'CVE-2026-97689.patch:3998fdced0f14d9f960c4ebb53be4342305f8cfc677da78c9d11f036efd2702f'
    'CVE-2025-66418.patch:a1b8bea76f993836541404bd21a65692e68d3cc9ed9a3845b50cfd2488661740'
    'CVE-2025-66471.patch:eea23e54a0a1124c90de4fb2a8dbe13925023bb718b76a916dd71e3ba6796fb3'
    'CVE-2026-21441.patch:33d018d0378da1588062af31ff422ee932ba81567b977871a7a25146132ffbf3'
    'CVE-2026-97687.patch:5e60845a9d461a3e248ae68ee94b88aaebf454b5e4bcbcf27fd4e2932727f12c'
)

for ITEM in "${PATCHES[@]}"; do
    NAME="${ITEM%%:*}"
    HASH="${ITEM#*:}"
    FILE="${PATCH_DIR}/${NAME}"

    [ -f "${FILE}" ] || die "Missing patch: ${NAME}"
    echo "${HASH}  ${FILE}" | sha256sum -c - \
        || die "Patch checksum mismatch: ${NAME}"

    git apply --unidiff-zero --check -p1 "${FILE}"
    git apply --unidiff-zero -p1 "${FILE}"
    echo "[PASS] ${NAME}"
done

mkdir -p "${WORK}/wheelhouse"

"${PYTHON}" -m pip wheel \
    --no-deps --no-cache-dir \
    --wheel-dir "${WORK}/wheelhouse" "${SOURCE}"

"${PYTHON}" -m pip install \
    --force-reinstall --no-index --no-deps \
    --find-links "${WORK}/wheelhouse" 'urllib3==1.26.20'

"${PYTHON}" -c 'import urllib3; assert urllib3.__version__ == "1.26.20"; print("[PASS] urllib3 version")'

for TEST in \
    test_urllib3_security_windows.py \
    test_CVE-2026-21441-compatibility.py \
    test_CVE-2026-21441-redirect.py
do
    "${PYTHON}" "${PATCH_DIR}/tests/${TEST}"
done

"${PYTHON}" -m pip check
echo '[PASS] Agent Unix urllib3 security build'
