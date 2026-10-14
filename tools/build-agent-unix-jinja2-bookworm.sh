#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm"
BUILD_ROOT="$(mktemp -d /tmp/padit-agent-unix-jinja2-XXXXXXXX)"

PYTHON="${RUNTIME_ROOT}/bin/python"
PIP="${RUNTIME_ROOT}/bin/pip"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

run() {
    echo ">>> $*"
    "$@"
}

[ -x "${PYTHON}" ] || die "Agent Python missing"

# 13. Build Jinja2 2.11.3 with xmlattr security backports
###############################################################################

echo
echo "============================================================"
echo " Building patched Jinja2 2.11.3 from source"
echo "============================================================"

JINJA2_VERSION="2.11.3"
JINJA2_BUILD_DIR="${BUILD_ROOT}/jinja2-${JINJA2_VERSION}-source"
JINJA2_SDIST_SHA256="a6d58433de0ae800347cab1fa3043cebbabe8baa9d29e668f1c768cb87a333c6"

JINJA2_PATCH="${REPO_ROOT}/utils/patch-jinja2-2.11.3/CVE-2024-22195-CVE-2024-34064.patch"
JINJA2_PATCH_SHA256="1fc110b20b369ffadc501ea06f6cc88c9fa7d09a7965472c7f6388fb2cc5248f"

JINJA2_SANDBOX_PATCH="${REPO_ROOT}/utils/patch-jinja2-2.11.3/CVE-2024-56326-CVE-2025-27516.patch"
JINJA2_SANDBOX_PATCH_SHA256="61e272f9ec3a062cd419f13a3e6c5d6520a2e1c42426cd08889563e1d3a59b31"

[ -f "${JINJA2_PATCH}" ] \
    || die "Jinja2 security patch not found: ${JINJA2_PATCH}"

ACTUAL_JINJA2_PATCH_SHA256="$(
    sha256sum "${JINJA2_PATCH}" | awk '{print $1}'
)"

[ "${ACTUAL_JINJA2_PATCH_SHA256}" = "${JINJA2_PATCH_SHA256}" ] \
    || die "Unexpected SHA256 for Jinja2 patch: ${ACTUAL_JINJA2_PATCH_SHA256}"

[ -f "${JINJA2_SANDBOX_PATCH}" ] \
    || die "Jinja2 sandbox security patch not found: ${JINJA2_SANDBOX_PATCH}"

ACTUAL_JINJA2_SANDBOX_PATCH_SHA256="$(
    sha256sum "${JINJA2_SANDBOX_PATCH}" | awk '{print $1}'
)"

[ "${ACTUAL_JINJA2_SANDBOX_PATCH_SHA256}" = "${JINJA2_SANDBOX_PATCH_SHA256}" ] \
    || die "Unexpected SHA256 for Jinja2 sandbox patch: ${ACTUAL_JINJA2_SANDBOX_PATCH_SHA256}"

[ ! -e "${JINJA2_BUILD_DIR}" ] || die "Jinja2 build directory exists"
mkdir -p "${JINJA2_BUILD_DIR}"
cd "${JINJA2_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "Jinja2==${JINJA2_VERSION}"

JINJA2_SDIST="Jinja2-${JINJA2_VERSION}.tar.gz"

[ -f "${JINJA2_SDIST}" ] \
    || die "Jinja2 source archive not found: ${JINJA2_SDIST}"

ACTUAL_JINJA2_SDIST_SHA256="$(
    sha256sum "${JINJA2_SDIST}" | awk '{print $1}'
)"

[ "${ACTUAL_JINJA2_SDIST_SHA256}" = "${JINJA2_SDIST_SHA256}" ] \
    || die "Unexpected SHA256 for Jinja2 source archive: ${ACTUAL_JINJA2_SDIST_SHA256}"

tar -xf "${JINJA2_SDIST}"

JINJA2_SRC_DIR="${JINJA2_BUILD_DIR}/Jinja2-${JINJA2_VERSION}"

[ -d "${JINJA2_SRC_DIR}" ] \
    || die "Jinja2 source directory not found: ${JINJA2_SRC_DIR}"

(
    cd "${JINJA2_SRC_DIR}"

    patch --dry-run -p1 < "${JINJA2_PATCH}" >/dev/null
    patch -p1 < "${JINJA2_PATCH}"

    patch --dry-run -p1 < "${JINJA2_SANDBOX_PATCH}" >/dev/null
    patch -p1 < "${JINJA2_SANDBOX_PATCH}"
)

echo ">>> Jinja2 CVE-2024-22195/CVE-2024-34064 backport applied."
echo ">>> Jinja2 CVE-2024-56326/CVE-2025-27516 sandbox backport applied."

JINJA2_WHEELHOUSE="${JINJA2_BUILD_DIR}/wheelhouse"
mkdir -p "${JINJA2_WHEELHOUSE}"

run "${PIP}" wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${JINJA2_WHEELHOUSE}" \
    "${JINJA2_SRC_DIR}"

run "${PIP}" install \
    --force-reinstall \
    --no-index \
    --no-deps \
    --find-links "${JINJA2_WHEELHOUSE}" \
    "Jinja2==${JINJA2_VERSION}"

"${PYTHON}" - <<'PYJINJA2'
import jinja2
from jinja2 import Environment

expected = "2.11.3"

if jinja2.__version__ != expected:
    raise SystemExit(
        "Unexpected Jinja2 version: %s (expected %s)"
        % (jinja2.__version__, expected)
    )

env = Environment()

good = env.from_string("{{ attrs|xmlattr }}").render(
    attrs={u"class": u"ok", u"data-id": u"42"}
)

if 'class="ok"' not in good or 'data-id="42"' not in good:
    raise AssertionError("Valid xmlattr regression: %r" % (good,))

for sep in (u"\t", u"\n", u"\f", u" ", u"/", u">", u"="):
    key = u"class%sonclick" % sep

    try:
        env.from_string("{{ attrs|xmlattr }}").render(
            attrs={key: u"alert(1)"}
        )
    except ValueError:
        pass
    else:
        raise AssertionError(
            "Invalid xmlattr key unexpectedly accepted: %r" % (key,)
        )

from jinja2.sandbox import SandboxedEnvironment
from jinja2.exceptions import SecurityError

sandbox_env = SandboxedEnvironment()

def call_filter(value, arg):
    return value(arg)

sandbox_env.filters["call"] = call_filter

indirect_format = sandbox_env.from_string(
    "{{ '{0.__class__}'.format | call(42) }}"
)

try:
    result = indirect_format.render()
except SecurityError:
    pass
else:
    if "__class__" in result or "int" in result:
        raise AssertionError(
            "Indirect str.format escaped sandbox: %r" % result
        )

attr_format = sandbox_env.from_string(
    "{{ ('{0.__class__}'|attr('format'))(42) }}"
)

try:
    result = attr_format.render()
except SecurityError:
    pass
else:
    if "__class__" in result or "int" in result:
        raise AssertionError(
            "attr('format') escaped sandbox: %r" % result
        )

class AttrCompatObject(object):
    value = "attribute-ok"

if env.from_string(
    "{{ obj|attr('value') }}"
).render(obj=AttrCompatObject()) != "attribute-ok":
    raise AssertionError("attr filter attribute lookup regression")

item_only = env.from_string(
    "{{ obj|attr('value') }}"
).render(obj={"value": "item-must-not-be-used"})

if item_only != "":
    raise AssertionError(
        "attr filter unexpectedly fell back to item lookup: %r"
        % item_only
    )

print(">>> Jinja2 version verified: %s" % jinja2.__version__)
print("CVE-2024-22195 REGRESSION TEST: PASS")
print("CVE-2024-34064 REGRESSION TEST: PASS")
print("CVE-2024-56326 REGRESSION TEST: PASS")
print("CVE-2025-27516 REGRESSION TEST: PASS")
print("JINJA2 ATTR COMPATIBILITY TEST: PASS")
PYJINJA2

echo ">>> Jinja2 2.11.3 patched build verified."

###############################################################################

echo "[PASS] Agent Unix Jinja2 security build"
