#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm/bin/python"
PATCH_DIR="${REPO_ROOT}/utils/patch-ujson-2.0.3"
WORK="$(mktemp -d /tmp/padit-agent-unix-ujson-XXXXXXXX)"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

[ -x "${PYTHON}" ] || die "Runtime agent Python absent"
[ ! -e "${WORK}" ] || die "Dossier de travail déjà présent : ${WORK}"

mkdir -p "${WORK}"
cd "${WORK}"

"${PYTHON}" -m pip download \
    --no-deps --no-binary=:all: \
    'ujson==2.0.3'

echo 'bd2deffc983827510e5145fb66e4cc0f577480c62fe0b4882139f8f7d27ae9a3  ujson-2.0.3.tar.gz' \
    | sha256sum -c -

tar -xzf ujson-2.0.3.tar.gz
cd ujson-2.0.3

PATCHES=(
    'CVE-2022-31116.patch:ccef883e16bbd8dad3b790f38ff2d324f5d0515a7e0d6f6377b86f509a6fb18d'
    'issue-334-buffer-overflow.patch:1ddba061ddc6e776e518a5a272d6d7ca0263bac3b5ee947f554abc82795658fd'
    'CVE-2022-31117.patch:bba4cdab6c20ea2455b6c278c6cea0e86e82c2ed4a7666f7db06ec831db69e52'
    'CVE-2026-44660.patch:09d96a036b39cd4c43555e210e53e778b216e83598f25d3a8bb984a7c4b8ad50'
    'CVE-2026-54911.patch:0cab6cbd582872db6703989d68cd3dcd1b087153c85c86cc1204e6b5096210b0'
)

for ITEM in "${PATCHES[@]}"; do
    NAME="${ITEM%%:*}"
    HASH="${ITEM#*:}"
    FILE="${PATCH_DIR}/${NAME}"

    [ -f "${FILE}" ] || die "Patch absent : ${NAME}"
    echo "${HASH}  ${FILE}" | sha256sum -c - \
        || die "Empreinte invalide : ${NAME}"

    patch --batch --forward --dry-run -p1 < "${FILE}"
    patch --batch --forward -p1 < "${FILE}"
    echo "[PASS] ${NAME}"
done

mkdir -p "${WORK}/wheelhouse"

"${PYTHON}" -m pip wheel \
    --no-deps --no-cache-dir \
    --wheel-dir "${WORK}/wheelhouse" \
    "${WORK}/ujson-2.0.3"

"${PYTHON}" -m pip install \
    --force-reinstall --no-deps --no-index \
    --find-links "${WORK}/wheelhouse" \
    'ujson==2.0.3'

"${PYTHON}" - "${WORK}/ujson-2.0.3" <<'PYUJSON'
import gc
import json
import os
import sys
import ujson

assert ujson.__version__ == '2.0.3'

for payload in (
    r'"\uD800"',
    r'"\uD800hello"',
    r'"\uDC00"',
    r'"\uD800foo bar\uDC00"',
    r'"\uD83D\uDCA9"',
):
    assert ujson.loads(payload) == json.loads(payload)

with open(os.path.join(sys.argv[1], 'tests', '334-reproducer.json'), 'rb') as f:
    data = ujson.loads(f.read())

for indent in (0, 1, 2, 4, 5, 8, 49):
    ujson.dumps(data, indent=indent)

for payload in (
    '\xc2A', '\xe2\x82A', '\xf0\x90\x80A',
    '\xf4\x90\x80\x80', '\xf5\x80\x80\x80',
    '\xc2', '\xe2\x82', '\xf0\x90\x80'
):
    try:
        ujson.dumps(payload)
    except (ValueError, OverflowError):
        pass
    else:
        raise AssertionError('Invalid UTF-8 accepted')

class FailingWriter(object):
    def write(self, data):
        raise IOError('simulated write failure')

writer = FailingWriter()
gc.collect()
before = sys.getrefcount(writer)

def run_test():
    for _ in range(1000):
        try:
            ujson.dump([1, 2, 3], writer)
        except IOError:
            pass
        else:
            raise AssertionError('Expected IOError')

run_test()
gc.collect()
assert sys.getrefcount(writer) == before

print('[PASS] ujson security regression tests')
PYUJSON

"${PYTHON}" -m pip check
echo '[PASS] U24 - ujson agent Unix sécurisé'
