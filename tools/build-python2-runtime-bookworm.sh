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
CYTHON_VERSION="3.0.9"

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
CRYPTOGRAPHY_REQUIREMENT_RE='^[[:space:]]*cryptography==3\.3\.2([[:space:]]*(#.*)?)?$'
CFFI_REQUIREMENT_RE='^[[:space:]]*cffi==1\.15\.1([[:space:]]*(#.*)?)?$'
LXML_REQUIREMENT_RE='^[[:space:]]*lxml==5\.0\.2([[:space:]]*(#.*)?)?$'
JINJA2_REQUIREMENT_RE='^[[:space:]]*Jinja2==2\.11\.3([[:space:]]*(#.*)?)?$'
FLASK_REQUIREMENT_RE='^[[:space:]]*Flask==1\.1\.4([[:space:]]*(#.*)?)?$'

UJSON_REQ_COUNT="$(
    grep -Ec "${UJSON_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${UJSON_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one ujson==2.0.3 requirement, found ${UJSON_REQ_COUNT}"

CRYPTOGRAPHY_REQ_COUNT="$(
    grep -Ec "${CRYPTOGRAPHY_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${CRYPTOGRAPHY_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one cryptography==3.3.2 requirement, found ${CRYPTOGRAPHY_REQ_COUNT}"

CFFI_REQ_COUNT="$(
    grep -Ec "${CFFI_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${CFFI_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one cffi==1.15.1 requirement, found ${CFFI_REQ_COUNT}"

LXML_REQ_COUNT="$(
    grep -Ec "${LXML_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${LXML_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one lxml==5.0.2 requirement, found ${LXML_REQ_COUNT}"

JINJA2_REQ_COUNT="$(
    grep -Ec "${JINJA2_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${JINJA2_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one Jinja2==2.11.3 requirement, found ${JINJA2_REQ_COUNT}"

FLASK_REQ_COUNT="$(
    grep -Ec "${FLASK_REQUIREMENT_RE}" \
        "${REPO_ROOT}/requirements-server.txt" || true
)"

[ "${FLASK_REQ_COUNT}" = "1" ] \
    || die "Expected exactly one Flask==1.1.4 requirement, found ${FLASK_REQ_COUNT}"

grep -Ev "${UJSON_REQUIREMENT_RE}|${CRYPTOGRAPHY_REQUIREMENT_RE}|${CFFI_REQUIREMENT_RE}|${LXML_REQUIREMENT_RE}|${JINJA2_REQUIREMENT_RE}|${FLASK_REQUIREMENT_RE}" \
    "${REPO_ROOT}/requirements-server.txt" \
    > "${SERVER_REQUIREMENTS}"

run "${PIP}" install \
    --no-cache-dir \
    -r "${SERVER_REQUIREMENTS}"

###############################################################################
# 10. Build cffi 1.15.1 from source
###############################################################################

echo
echo "============================================================"
echo " Building cffi 1.15.1 from source"
echo "============================================================"

CFFI_VERSION="1.15.1"
CFFI_BUILD_DIR="${BUILD_ROOT}/cffi-${CFFI_VERSION}-source"
CFFI_SDIST_SHA256="d400bfb9a37b1351253cb402671cea7e89bdecc294e8016a707f6d1d8ac934f9"

rm -rf "${CFFI_BUILD_DIR}"
mkdir -p "${CFFI_BUILD_DIR}"
cd "${CFFI_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "cffi==${CFFI_VERSION}"

CFFI_SDIST="cffi-${CFFI_VERSION}.tar.gz"

[ -f "${CFFI_SDIST}" ] \
    || die "cffi source archive not found: ${CFFI_SDIST}"

ACTUAL_CFFI_SDIST_SHA256="$(
    sha256sum "${CFFI_SDIST}" | awk '{print $1}'
)"

[ "${ACTUAL_CFFI_SDIST_SHA256}" = "${CFFI_SDIST_SHA256}" ] \
    || die "Unexpected SHA256 for cffi source archive: ${ACTUAL_CFFI_SDIST_SHA256}"

tar -xf "${CFFI_SDIST}"

CFFI_SRC_DIR="${CFFI_BUILD_DIR}/cffi-${CFFI_VERSION}"

[ -d "${CFFI_SRC_DIR}" ] \
    || die "cffi source directory not found: ${CFFI_SRC_DIR}"

CFFI_WHEELHOUSE="${CFFI_BUILD_DIR}/wheelhouse"
mkdir -p "${CFFI_WHEELHOUSE}"

run "${PIP}" wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${CFFI_WHEELHOUSE}" \
    "${CFFI_SRC_DIR}"

run "${PIP}" install \
    --force-reinstall \
    --no-index \
    --no-deps \
    --find-links "${CFFI_WHEELHOUSE}" \
    "cffi==${CFFI_VERSION}"

"${PYTHON}" - <<'PYCFFI'
import cffi

expected_version = "1.15.1"

if cffi.__version__ != expected_version:
    raise SystemExit(
        "Unexpected cffi version: %s (expected %s)"
        % (cffi.__version__, expected_version)
    )

print(">>> cffi version verified: %s" % cffi.__version__)
print("CFFI 1.15.1 SOURCE BUILD TEST: PASS")
PYCFFI

###############################################################################
# 11. Build cryptography 3.3.2 against system OpenSSL 3
###############################################################################

echo
echo "============================================================"
echo " Building cryptography 3.3.2 against system OpenSSL 3"
echo "============================================================"

CRYPTOGRAPHY_VERSION="3.3.2"
CRYPTOGRAPHY_BUILD_DIR="${BUILD_ROOT}/cryptography-${CRYPTOGRAPHY_VERSION}-patched"

CRYPTOGRAPHY_PATCH_OPENSSL3="${REPO_ROOT}/utils/patch-cryptography-3.3.2/openssl3-compat.patch"
CRYPTOGRAPHY_PATCH_OPENSSL3_SHA256="2d2529dad4c11757524942ff797937c03573f1dcb12f32aefc2ee8227f1af626"

CRYPTOGRAPHY_PATCH_CVE_2023_49083="${REPO_ROOT}/utils/patch-cryptography-3.3.2/CVE-2023-49083.patch"
CRYPTOGRAPHY_PATCH_CVE_2023_49083_SHA256="3ce50d0c316ac82c00824d45777cd5e23f0aaad329fa4088df1a097936c0e162"

CRYPTOGRAPHY_SDIST_SHA256="5a60d3780149e13b7a6ff7ad6526b38846354d11a15e21068e57073e29e19bed"

for CRYPTOGRAPHY_PATCH in \
    "${CRYPTOGRAPHY_PATCH_OPENSSL3}" \
    "${CRYPTOGRAPHY_PATCH_CVE_2023_49083}"
do
    [ -f "${CRYPTOGRAPHY_PATCH}" ] \
        || die "cryptography patch not found: ${CRYPTOGRAPHY_PATCH}"
done

ACTUAL_CRYPTOGRAPHY_PATCH_SHA256="$(
    sha256sum "${CRYPTOGRAPHY_PATCH_OPENSSL3}" | awk '{print $1}'
)"

[ "${ACTUAL_CRYPTOGRAPHY_PATCH_SHA256}" = "${CRYPTOGRAPHY_PATCH_OPENSSL3_SHA256}" ] \
    || die "Unexpected SHA256 for cryptography OpenSSL 3 patch: ${ACTUAL_CRYPTOGRAPHY_PATCH_SHA256}"

ACTUAL_CRYPTOGRAPHY_PATCH_SHA256="$(
    sha256sum "${CRYPTOGRAPHY_PATCH_CVE_2023_49083}" | awk '{print $1}'
)"

[ "${ACTUAL_CRYPTOGRAPHY_PATCH_SHA256}" = "${CRYPTOGRAPHY_PATCH_CVE_2023_49083_SHA256}" ] \
    || die "Unexpected SHA256 for cryptography CVE-2023-49083 patch: ${ACTUAL_CRYPTOGRAPHY_PATCH_SHA256}"

rm -rf "${CRYPTOGRAPHY_BUILD_DIR}"
mkdir -p "${CRYPTOGRAPHY_BUILD_DIR}"
cd "${CRYPTOGRAPHY_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "cryptography==${CRYPTOGRAPHY_VERSION}"

CRYPTOGRAPHY_SDIST="cryptography-${CRYPTOGRAPHY_VERSION}.tar.gz"

[ -f "${CRYPTOGRAPHY_SDIST}" ] \
    || die "cryptography source archive not found: ${CRYPTOGRAPHY_SDIST}"

ACTUAL_CRYPTOGRAPHY_SDIST_SHA256="$(
    sha256sum "${CRYPTOGRAPHY_SDIST}" | awk '{print $1}'
)"

[ "${ACTUAL_CRYPTOGRAPHY_SDIST_SHA256}" = "${CRYPTOGRAPHY_SDIST_SHA256}" ] \
    || die "Unexpected SHA256 for cryptography source archive: ${ACTUAL_CRYPTOGRAPHY_SDIST_SHA256}"

tar -xf "${CRYPTOGRAPHY_SDIST}"

CRYPTOGRAPHY_SRC_DIR="${CRYPTOGRAPHY_BUILD_DIR}/cryptography-${CRYPTOGRAPHY_VERSION}"

[ -d "${CRYPTOGRAPHY_SRC_DIR}" ] \
    || die "cryptography source directory not found: ${CRYPTOGRAPHY_SRC_DIR}"

(
    cd "${CRYPTOGRAPHY_SRC_DIR}"

    for CRYPTOGRAPHY_PATCH in \
        "${CRYPTOGRAPHY_PATCH_OPENSSL3}" \
        "${CRYPTOGRAPHY_PATCH_CVE_2023_49083}"
    do
        patch --dry-run -p1 < "${CRYPTOGRAPHY_PATCH}" >/dev/null
        patch -p1 < "${CRYPTOGRAPHY_PATCH}"
    done
)

echo ">>> cryptography OpenSSL 3 compatibility patch applied."
echo ">>> cryptography CVE-2023-49083 backport applied."

CRYPTOGRAPHY_WHEELHOUSE="${CRYPTOGRAPHY_BUILD_DIR}/wheelhouse"
mkdir -p "${CRYPTOGRAPHY_WHEELHOUSE}"

run "${PIP}" wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${CRYPTOGRAPHY_WHEELHOUSE}" \
    "${CRYPTOGRAPHY_SRC_DIR}"

run "${PIP}" install \
    --force-reinstall \
    --no-index \
    --no-deps \
    --find-links "${CRYPTOGRAPHY_WHEELHOUSE}" \
    "cryptography==${CRYPTOGRAPHY_VERSION}"

"${PYTHON}" - <<'PYCRYPTOGRAPHY'
import datetime

import cryptography
from cryptography import x509
from cryptography.hazmat.backends.openssl.backend import backend
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs7
from cryptography.x509.oid import NameOID

expected_version = "3.3.2"

if cryptography.__version__ != expected_version:
    raise SystemExit(
        "Unexpected cryptography version: %s (expected %s)"
        % (cryptography.__version__, expected_version)
    )

if backend.openssl_version_number() < 0x30000000:
    raise SystemExit(
        "cryptography is not using OpenSSL 3: %s"
        % backend.openssl_version_text()
    )

key = rsa.generate_private_key(
    public_exponent=65537,
    key_size=2048,
)

name = x509.Name([
    x509.NameAttribute(NameOID.COMMON_NAME, u"PADIT CVE-2023-49083 test"),
])

now = datetime.datetime.utcnow()

cert = (
    x509.CertificateBuilder()
    .subject_name(name)
    .issuer_name(name)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(days=1))
    .not_valid_after(now + datetime.timedelta(days=1))
    .sign(key, hashes.SHA256())
)

builder = (
    pkcs7.PKCS7SignatureBuilder()
    .set_data(b"PADIT CVE-2023-49083 regression test")
    .add_signer(cert, key, hashes.SHA256())
)

sig_no_certs = builder.sign(
    serialization.Encoding.DER,
    [pkcs7.PKCS7Options.NoCerts],
)

loaded = pkcs7.load_der_pkcs7_certificates(sig_no_certs)

if loaded != []:
    raise AssertionError(
        "CVE-2023-49083 regression: expected empty certificate list, got %r"
        % (loaded,)
    )

print(">>> cryptography version verified: %s" % cryptography.__version__)
print(">>> cryptography OpenSSL backend: %s" % backend.openssl_version_text())
print("CRYPTOGRAPHY 3.3.2 SYSTEM OPENSSL 3 TEST: PASS")
print("CRYPTOGRAPHY CVE-2023-49083 REGRESSION TEST: PASS")
PYCRYPTOGRAPHY

###############################################################################
# 12. Build ujson 2.0.3 with security backports
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

rm -rf "${JINJA2_BUILD_DIR}"
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
# 14. Build Flask 1.1.4 with session security backports
###############################################################################

echo
echo "============================================================"
echo " Building patched Flask 1.1.4 from source"
echo "============================================================"

FLASK_VERSION="1.1.4"
FLASK_BUILD_DIR="${BUILD_ROOT}/flask-${FLASK_VERSION}-source"
FLASK_SDIST_SHA256="0fbeb6180d383a9186d0d6ed954e0042ad9f18e0e8de088b2b419d526927d196"

FLASK_PATCH="${REPO_ROOT}/utils/patch-flask-1.1.4/CVE-2023-30861-CVE-2026-27205.patch"
FLASK_PATCH_SHA256="4b2a84ccdc10495db631719f1b58fa16e2c4a7def27695ff39e6a0e3c1cc3312"

[ -f "${FLASK_PATCH}" ] \
    || die "Flask security patch not found: ${FLASK_PATCH}"

ACTUAL_FLASK_PATCH_SHA256="$(
    sha256sum "${FLASK_PATCH}" | awk '{print $1}'
)"

[ "${ACTUAL_FLASK_PATCH_SHA256}" = "${FLASK_PATCH_SHA256}" ] \
    || die "Unexpected SHA256 for Flask patch: ${ACTUAL_FLASK_PATCH_SHA256}"

rm -rf "${FLASK_BUILD_DIR}"
mkdir -p "${FLASK_BUILD_DIR}"
cd "${FLASK_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "Flask==${FLASK_VERSION}"

FLASK_SDIST="Flask-${FLASK_VERSION}.tar.gz"

[ -f "${FLASK_SDIST}" ] \
    || die "Flask source archive not found: ${FLASK_SDIST}"

ACTUAL_FLASK_SDIST_SHA256="$(
    sha256sum "${FLASK_SDIST}" | awk '{print $1}'
)"

[ "${ACTUAL_FLASK_SDIST_SHA256}" = "${FLASK_SDIST_SHA256}" ] \
    || die "Unexpected SHA256 for Flask source archive: ${ACTUAL_FLASK_SDIST_SHA256}"

tar -xf "${FLASK_SDIST}"

FLASK_SRC_DIR="${FLASK_BUILD_DIR}/Flask-${FLASK_VERSION}"

[ -d "${FLASK_SRC_DIR}" ] \
    || die "Flask source directory not found: ${FLASK_SRC_DIR}"

(
    cd "${FLASK_SRC_DIR}"
    patch --dry-run -p1 < "${FLASK_PATCH}" >/dev/null
    patch -p1 < "${FLASK_PATCH}"
)

echo ">>> Flask CVE-2023-30861/CVE-2026-27205 backport applied."

FLASK_WHEELHOUSE="${FLASK_BUILD_DIR}/wheelhouse"
mkdir -p "${FLASK_WHEELHOUSE}"

run "${PIP}" wheel \
    --no-deps \
    --no-cache-dir \
    --wheel-dir "${FLASK_WHEELHOUSE}" \
    "${FLASK_SRC_DIR}"

run "${PIP}" install \
    --force-reinstall \
    --no-index \
    --no-deps \
    --find-links "${FLASK_WHEELHOUSE}" \
    "Flask==${FLASK_VERSION}"

"${PYTHON}" - <<'PYFLASK'
import flask

from flask import Flask
from flask import session
from flask.globals import _request_ctx_stack
from flask.sessions import SecureCookieSession

expected = "1.1.4"

if flask.__version__ != expected:
    raise SystemExit(
        "Unexpected Flask version: %s (expected %s)"
        % (flask.__version__, expected)
    )

# CVE-2023-30861:
# A permanent session refreshed without explicit access must still emit
# Vary: Cookie when Flask rewrites the cookie.
app = Flask(__name__)
app.secret_key = "padit-regression-test"
app.config["SESSION_REFRESH_EACH_REQUEST"] = True

test_session = SecureCookieSession(
    {"_permanent": True, "user": "alice"}
)
test_session.modified = False
test_session.accessed = False

response = app.response_class()
app.session_interface.save_session(app, test_session, response)

if not response.headers.get("Set-Cookie"):
    raise AssertionError(
        "Permanent session refresh did not emit Set-Cookie"
    )

if "Cookie" not in response.vary:
    raise AssertionError(
        "Vary: Cookie missing when session cookie was refreshed"
    )

# Deleting a modified empty session cookie must also vary on Cookie.
empty_session = SecureCookieSession()
empty_session.modified = True
empty_session.accessed = False

delete_response = app.response_class()
app.session_interface.save_session(
    app, empty_session, delete_response
)

if "Cookie" not in delete_response.vary:
    raise AssertionError(
        "Vary: Cookie missing when session cookie was deleted"
    )

# CVE-2026-27205:
# Resolving flask.session must mark the session accessed regardless
# of the particular mapping operation subsequently performed.
with app.test_request_context("/"):
    ctx = _request_ctx_stack.top

    ctx.session["user"] = "alice"
    ctx.session.modified = False
    ctx.session.accessed = False

    if ("user" in session) is not True:
        raise AssertionError("session containment lookup failed")

    if not ctx.session.accessed:
        raise AssertionError(
            "session containment lookup did not mark session accessed"
        )

    ctx.session.accessed = False

    if len(session) != 1:
        raise AssertionError(
            "Unexpected session length: %r" % len(session)
        )

    if not ctx.session.accessed:
        raise AssertionError(
            "session len lookup did not mark session accessed"
        )

# Internal request processing itself must not spuriously mark an unused
# session as accessed.
app2 = Flask("padit-no-session-access")
app2.secret_key = "padit-regression-test"

@app2.route("/")
def no_session_access():
    return "ok"

client = app2.test_client()
response = client.get("/")

if "Cookie" in response.vary:
    raise AssertionError(
        "Unused session was spuriously marked as accessed"
    )

print(">>> Flask version verified: %s" % flask.__version__)
print("CVE-2023-30861 REGRESSION TEST: PASS")
print("CVE-2026-27205 IN-OPERATOR TEST: PASS")
print("CVE-2026-27205 LEN TEST: PASS")
print("FLASK UNUSED SESSION COMPATIBILITY TEST: PASS")
PYFLASK

echo ">>> Flask 1.1.4 patched build verified."

###############################################################################
# 15. Build patched lxml 5.0.2 from source
###############################################################################

echo
echo "============================================================"
echo " Building patched lxml 5.0.2 from source"
echo "============================================================"

LXML_VERSION="5.0.2"
LXML_BUILD_DIR="${BUILD_ROOT}/lxml-${LXML_VERSION}-source"
LXML_SDIST_SHA256="6399703c40ba53e2c3b72fdb56cb908d2b83c08082ecf17de839b27e68d1e598"

LXML_PATCH="${REPO_ROOT}/utils/patch-lxml-5.0.2/resolve-external-entities-default.patch"
LXML_PATCH_SHA256="f5d605fc9513ce88907bae0f00f56d04070dfe3bc60d99284ea86308f2ecc06e"

[ -f "${LXML_PATCH}" ] \
    || die "lxml security patch not found: ${LXML_PATCH}"

ACTUAL_LXML_PATCH_SHA256="$(
    sha256sum "${LXML_PATCH}" | awk '{print $1}'
)"

[ "${ACTUAL_LXML_PATCH_SHA256}" = "${LXML_PATCH_SHA256}" ] \
    || die "Unexpected SHA256 for lxml patch: ${ACTUAL_LXML_PATCH_SHA256}"

rm -rf "${LXML_BUILD_DIR}"
mkdir -p "${LXML_BUILD_DIR}"
cd "${LXML_BUILD_DIR}"

run "${PIP}" download \
    --no-deps \
    --no-binary=:all: \
    "lxml==${LXML_VERSION}"

LXML_SDIST="lxml-${LXML_VERSION}.tar.gz"

[ -f "${LXML_SDIST}" ] \
    || die "lxml source archive not found: ${LXML_SDIST}"

ACTUAL_LXML_SDIST_SHA256="$(
    sha256sum "${LXML_SDIST}" | awk '{print $1}'
)"

[ "${ACTUAL_LXML_SDIST_SHA256}" = "${LXML_SDIST_SHA256}" ] \
    || die "Unexpected SHA256 for lxml source archive: ${ACTUAL_LXML_SDIST_SHA256}"

tar -xf "${LXML_SDIST}"

LXML_SRC_DIR="${LXML_BUILD_DIR}/lxml-${LXML_VERSION}"

[ -d "${LXML_SRC_DIR}" ] \
    || die "lxml source directory not found: ${LXML_SRC_DIR}"

(
    cd "${LXML_SRC_DIR}"
    patch --dry-run -p1 < "${LXML_PATCH}" >/dev/null
    patch -p1 < "${LXML_PATCH}"
)

echo ">>> lxml external entity default hardening patch applied."

LXML_CYTHON_DIR="${BUILD_ROOT}/cython-${CYTHON_VERSION}-target"

rm -rf "${LXML_CYTHON_DIR}"
mkdir -p "${LXML_CYTHON_DIR}"

run python3 -m pip install \
    --no-cache-dir \
    --target "${LXML_CYTHON_DIR}" \
    "Cython==${CYTHON_VERSION}"

LXML_ACTUAL_CYTHON_VERSION="$(
    PYTHONPATH="${LXML_CYTHON_DIR}" python3 - <<'PYLXMLCYTHON'
import Cython
print(Cython.__version__)
PYLXMLCYTHON
)"

[ "${LXML_ACTUAL_CYTHON_VERSION}" = "${CYTHON_VERSION}" ] \
    || die "Unexpected Cython version: ${LXML_ACTUAL_CYTHON_VERSION}"

(
    cd "${LXML_SRC_DIR}"

    PYTHONPATH="${LXML_CYTHON_DIR}" \
        python3 setup.py build_ext --with-cython
)

grep -q "Generated by Cython ${CYTHON_VERSION}" \
    "${LXML_SRC_DIR}/src/lxml/etree.c" \
    || die "lxml etree.c was not regenerated with Cython ${CYTHON_VERSION}"

grep -q "resolve_entities='internal'" \
    "${LXML_SRC_DIR}/src/lxml/etree.c" \
    || die "lxml resolve_entities hardening marker not found in etree.c"

(
    cd "${LXML_SRC_DIR}"
    rm -rf build dist
    run "${PYTHON}" setup.py bdist_wheel
)

LXML_BUILT_WHEEL="$(
    find "${LXML_SRC_DIR}/dist" \
        -maxdepth 1 \
        -type f \
        -name "lxml-${LXML_VERSION}-cp27-*.whl" \
        -print \
        | head -1
)"

[ -n "${LXML_BUILT_WHEEL}" ] \
    || die "lxml Python 2 wheel not found"

LXML_WHEELHOUSE="${LXML_BUILD_DIR}/wheelhouse"

rm -rf "${LXML_WHEELHOUSE}"
mkdir -p "${LXML_WHEELHOUSE}"

cp "${LXML_BUILT_WHEEL}" "${LXML_WHEELHOUSE}/"

run "${PIP}" install \
    --no-index \
    --no-deps \
    --find-links "${LXML_WHEELHOUSE}" \
    "lxml==${LXML_VERSION}"

"${PYTHON}" - <<'PYLXML'
import lxml
from lxml import etree

expected = "5.0.2"
actual = lxml.__version__

if actual != expected:
    raise SystemExit(
        "Unexpected lxml version: %s (expected %s)"
        % (actual, expected)
    )

xml_internal = (
    '<!DOCTYPE root [<!ENTITY x "INTERNAL_OK">]>'
    '<root>&x;</root>'
)

root = etree.fromstring(xml_internal)

if root.text != "INTERNAL_OK":
    raise AssertionError(
        "Internal entity regression: %r" % (root.text,)
    )

xml_external = (
    '<!DOCTYPE root ['
    '<!ENTITY ext SYSTEM "file:///etc/hostname">'
    ']>'
    '<root>&ext;</root>'
)

try:
    etree.fromstring(xml_external)
except etree.XMLSyntaxError:
    pass
else:
    raise AssertionError(
        "External entity unexpectedly resolved with default parser"
    )

etree.XMLParser(resolve_entities=True, no_network=True)

print(">>> lxml version verified: %s" % actual)
print("lxml internal entity default: PASS")
print("lxml external entity default blocking: PASS")
print("lxml explicit resolve_entities=True parser creation: PASS")
PYLXML

echo ">>> lxml 5.0.2 patched build verified."

###############################################################################
# 16. Apply urllib3 CVE-2026-97689 compatibility backport
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
# 17. Apply urllib3 CVE-2025-66418 decompression-chain backport
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
# 18. Apply urllib3 CVE-2025-66471 streaming decompression backport
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
# requests common setup
###############################################################################

REQUESTS_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/requests"

[ -d "${REQUESTS_DIR}" ] \
    || die "requests directory not found: ${REQUESTS_DIR}"

REQUESTS_VERSION="$("${PYTHON}" -c 'import requests; print(requests.__version__)')"

[ "${REQUESTS_VERSION}" = "2.27.1" ] \
    || die "Unexpected requests version: ${REQUESTS_VERSION}"

echo ">>> requests version verified: ${REQUESTS_VERSION}"

###############################################################################
# 19. Apply requests CVE-2023-32681 proxy authorization leak backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2023-32681 backport"
echo "============================================================"

REQUESTS_PATCH_32681="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2023-32681.patch"
REQUESTS_PATCH_32681_SHA256="003eb163893c401f94e65172b6e11e659d4a5983e8cf6f85eed43e674dd8eca2"

[ -f "${REQUESTS_PATCH_32681}" ] \
    || die "requests CVE-2023-32681 patch not found: ${REQUESTS_PATCH_32681}"

ACTUAL_REQUESTS_PATCH_32681_SHA256="$(
    sha256sum "${REQUESTS_PATCH_32681}" | awk '{print $1}'
)"

[ "${ACTUAL_REQUESTS_PATCH_32681_SHA256}" = "${REQUESTS_PATCH_32681_SHA256}" ] \
    || die "Unexpected SHA256 for requests CVE-2023-32681 patch: ${ACTUAL_REQUESTS_PATCH_32681_SHA256}"

if grep -q "if not scheme.startswith('https') and username and password:" \
    "${REQUESTS_DIR}/sessions.py"; then
    echo ">>> requests CVE-2023-32681 backport already present."
else
    (
        cd "${REQUESTS_DIR}"
        patch --dry-run -p1 < "${REQUESTS_PATCH_32681}" >/dev/null
        patch -p1 < "${REQUESTS_PATCH_32681}"
    )
    echo ">>> requests CVE-2023-32681 backport applied."
fi

"${PYTHON}" -m py_compile "${REQUESTS_DIR}/sessions.py"

echo ">>> Running CVE-2023-32681 regression test..."

"${PYTHON}" - <<'PYTEST'
import requests

session = requests.Session()
session.trust_env = False

proxies = {
    "http": "http://test:pass@localhost:8080",
    "https": "http://test:pass@localhost:8090",
}

cases = [
    ("http://example.com", True),
    ("https://example.com", False),
]

for url, should_have_auth in cases:
    req = requests.Request("GET", url)
    prep = req.prepare()

    session.rebuild_proxies(prep, proxies)

    has_auth = "Proxy-Authorization" in prep.headers

    if has_auth != should_have_auth:
        raise RuntimeError(
            "Unexpected Proxy-Authorization state for %s: %r"
            % (url, prep.headers.get("Proxy-Authorization"))
        )

print("CVE-2023-32681 PROXY AUTH LEAK TEST: PASS")
PYTEST

echo ">>> requests CVE-2023-32681 backport verified."

###############################################################################
# 20. Apply requests CVE-2024-35195 TLS pool isolation backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2024-35195 backport"
echo "============================================================"

REQUESTS_PATCH_35195="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2024-35195.patch"
REQUESTS_PATCH_35195_SHA256="4af162e6e503f464ae8a62fb208e89d4427f3349606014c2c22901f02a8451d8"

[ -f "${REQUESTS_PATCH_35195}" ] \
    || die "requests security patch not found: ${REQUESTS_PATCH_35195}"

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
# 21. Apply requests CVE-2024-47081 netrc hostname backport
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
# 22. Apply requests CVE-2026-25645 temporary-file backport
###############################################################################

echo
echo "============================================================"
echo " Applying requests CVE-2026-25645 backport"
echo "============================================================"

REQUESTS_PATCH_25645="${REPO_ROOT}/utils/patch-requests-2.27.1/CVE-2026-25645.patch"
REQUESTS_PATCH_25645_SHA256="8b3a91cf7e963b2fa50311525db2b23f297c966fd1860042190019443384937a"

[ -f "${REQUESTS_PATCH_25645}" ] \
    || die "requests security patch not found: ${REQUESTS_PATCH_25645}"

ACTUAL_REQUESTS_PATCH_SHA256="$(
    sha256sum "${REQUESTS_PATCH_25645}" | awk '{print $1}'
)"

[ "${ACTUAL_REQUESTS_PATCH_SHA256}" = "${REQUESTS_PATCH_25645_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2026-25645 patch: ${ACTUAL_REQUESTS_PATCH_SHA256}"

if grep -q 'fd, extracted_path = tempfile.mkstemp(suffix=suffix)' \
    "${REQUESTS_DIR}/utils.py"; then
    echo ">>> requests CVE-2026-25645 backport already present."
else
    (
        cd "${REQUESTS_DIR}"
        patch --dry-run -p1 < "${REQUESTS_PATCH_25645}" >/dev/null
        patch -p1 < "${REQUESTS_PATCH_25645}"
    )
    echo ">>> requests CVE-2026-25645 backport applied."
fi

"${PYTHON}" -m py_compile "${REQUESTS_DIR}/utils.py"

grep -q 'fd, extracted_path = tempfile.mkstemp(suffix=suffix)' \
    "${REQUESTS_DIR}/utils.py" \
    || die "requests secure temporary-file marker not found"

echo ">>> Running CVE-2026-25645 regression test..."

"${PYTHON}" - <<'PYTEST'
import os
import tempfile
import zipfile
import requests

fd, zip_path = tempfile.mkstemp(prefix='padit-requests-', suffix='.zip')
os.close(fd)

payload = 'PADIT-CVE-2026-25645'

try:
    z = zipfile.ZipFile(zip_path, 'w')
    z.writestr('nested/test.txt', payload)
    z.close()

    virtual_path = zip_path + os.sep + 'nested' + os.sep + 'test.txt'

    extracted1 = requests.utils.extract_zipped_paths(virtual_path)
    extracted2 = requests.utils.extract_zipped_paths(virtual_path)

    if extracted1 == extracted2:
        raise RuntimeError(
            "CVE-2026-25645 regression: temporary path was reused"
        )

    for extracted in (extracted1, extracted2):
        if not os.path.isfile(extracted):
            raise RuntimeError(
                "CVE-2026-25645 regression: extracted file missing"
            )
        with open(extracted, 'rb') as f:
            if f.read() != payload:
                raise RuntimeError(
                    "CVE-2026-25645 regression: extracted content mismatch"
                )

    print("CVE-2026-25645 TEMP FILE UNIQUENESS TEST: PASS")

finally:
    for name in ('extracted1', 'extracted2'):
        if name in locals():
            extracted = locals()[name]
            if os.path.exists(extracted):
                os.unlink(extracted)

    if os.path.exists(zip_path):
        os.unlink(zip_path)
PYTEST

echo ">>> requests CVE-2026-25645 backport verified."

###############################################################################
# 23. Apply Werkzeug CVE-2023-23934 cookie parsing backport
###############################################################################

echo
echo "============================================================"
echo " Applying Werkzeug CVE-2023-23934 backport"
echo "============================================================"

WERKZEUG_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/werkzeug"
WERKZEUG_PATCH_23934="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/CVE-2023-23934.patch"
WERKZEUG_PATCH_23934_SHA256="9e682a6132ffcac899723307e8098ed6adee57cd69218a938c1e5b13c315514e"

[ -d "${WERKZEUG_DIR}" ] \
    || die "Werkzeug directory not found: ${WERKZEUG_DIR}"

[ -f "${WERKZEUG_PATCH_23934}" ] \
    || die "Werkzeug security patch not found: ${WERKZEUG_PATCH_23934}"

WERKZEUG_VERSION="$("${PYTHON}" -c 'import werkzeug; print(werkzeug.__version__)')"

[ "${WERKZEUG_VERSION}" = "1.0.1" ] \
    || die "Unexpected Werkzeug version: ${WERKZEUG_VERSION}"

echo ">>> Werkzeug version verified: ${WERKZEUG_VERSION}"

ACTUAL_WERKZEUG_PATCH_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_23934}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_SHA256}" = "${WERKZEUG_PATCH_23934_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2023-23934 patch: ${ACTUAL_WERKZEUG_PATCH_SHA256}"

if grep -q 'match = _cookie_re.match(b, i)' \
    "${WERKZEUG_DIR}/_internal.py" \
    && grep -q 'b += b";"' "${WERKZEUG_DIR}/_internal.py"; then
    echo ">>> Werkzeug CVE-2023-23934 backport already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_23934}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_23934}"
    )
    echo ">>> Werkzeug CVE-2023-23934 backport applied."
fi

"${PYTHON}" -m py_compile "${WERKZEUG_DIR}/_internal.py"

grep -q 'match = _cookie_re.match(b, i)' \
    "${WERKZEUG_DIR}/_internal.py" \
    || die "Werkzeug CVE-2023-23934 match marker not found"

grep -q 'b += b";"' \
    "${WERKZEUG_DIR}/_internal.py" \
    || die "Werkzeug CVE-2023-23934 input terminator marker not found"

echo ">>> Running CVE-2023-23934 regression test..."

"${PYTHON}" - <<'PYTEST'
from werkzeug.http import parse_cookie

header = '==__Host-eq=bad;__Host-eq=good;'
cookies = parse_cookie(header)

if cookies.get('__Host-eq') != 'good':
    raise RuntimeError(
        "CVE-2023-23934 regression: malformed cookie took precedence"
    )

if cookies.getlist('__Host-eq') != ['good']:
    raise RuntimeError(
        "CVE-2023-23934 regression: malformed cookie was not discarded"
    )

print("CVE-2023-23934 COOKIE PARSING TEST: PASS")
PYTEST

echo ">>> Werkzeug CVE-2023-23934 backport verified."

###############################################################################
# 24. Apply Werkzeug CVE-2023-25577 multipart part limit backport
###############################################################################

echo
echo "============================================================"
echo " Applying Werkzeug CVE-2023-25577 backport"
echo "============================================================"

WERKZEUG_PATCH_25577="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/CVE-2023-25577.patch"
WERKZEUG_PATCH_25577_SHA256="2e40f24444ec9adbc8297550116ceaf17506c8cf6887fa4db4a0201e066866ec"

[ -f "${WERKZEUG_PATCH_25577}" ] \
    || die "Werkzeug security patch not found: ${WERKZEUG_PATCH_25577}"

ACTUAL_WERKZEUG_PATCH_25577_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_25577}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_25577_SHA256}" = "${WERKZEUG_PATCH_25577_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2023-25577 patch: ${ACTUAL_WERKZEUG_PATCH_25577_SHA256}"

if grep -q 'max_form_parts = 1000' \
    "${WERKZEUG_DIR}/wrappers/base_request.py" \
    && grep -q 'parts > self.max_form_parts' \
    "${WERKZEUG_DIR}/formparser.py"; then
    echo ">>> Werkzeug CVE-2023-25577 backport already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_25577}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_25577}"
    )
    echo ">>> Werkzeug CVE-2023-25577 backport applied."
fi

"${PYTHON}" -m py_compile \
    "${WERKZEUG_DIR}/formparser.py" \
    "${WERKZEUG_DIR}/wrappers/base_request.py"

grep -q 'max_form_parts = 1000' \
    "${WERKZEUG_DIR}/wrappers/base_request.py" \
    || die "Werkzeug CVE-2023-25577 request limit marker not found"

grep -q 'parts > self.max_form_parts' \
    "${WERKZEUG_DIR}/formparser.py" \
    || die "Werkzeug CVE-2023-25577 parser limit marker not found"

echo ">>> Running CVE-2023-25577 regression test..."

"${PYTHON}" - <<'PYTEST'
from io import BytesIO

from werkzeug.exceptions import RequestEntityTooLarge
from werkzeug.wrappers import Request


def make_request(count):
    boundary = b"PADITBOUNDARY"
    parts = []

    for i in range(count):
        parts.append(
            b"--" + boundary + b"\r\n"
            b"Content-Disposition: form-data; name=\"field%d\"\r\n"
            b"\r\n"
            b"x\r\n" % i
        )

    parts.append(b"--" + boundary + b"--\r\n")
    data = b"".join(parts)

    return Request.from_values(
        input_stream=BytesIO(data),
        content_length=len(data),
        content_type="multipart/form-data; boundary=PADITBOUNDARY",
        method="POST",
    )


req = make_request(1000)

if len(req.form) != 1000:
    raise RuntimeError(
        "CVE-2023-25577 regression: 1000 multipart parts were not accepted"
    )

req = make_request(1001)

try:
    req.form
except RequestEntityTooLarge:
    pass
else:
    raise RuntimeError(
        "CVE-2023-25577 regression: 1001 multipart parts were accepted"
    )

print("CVE-2023-25577 MULTIPART PART LIMIT TEST: PASS")
PYTEST

echo ">>> Werkzeug CVE-2023-25577 backport verified."

###############################################################################
# 25. Apply Werkzeug CVE-2024-34069 debugger host trust backport
###############################################################################

echo
echo "============================================================"
echo " Applying Werkzeug CVE-2024-34069 backport"
echo "============================================================"

WERKZEUG_PATCH_34069="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/CVE-2024-34069.patch"
WERKZEUG_PATCH_34069_SHA256="69c1b353edb4b311a532c8fd81e9f3de07a30951a064165047250c28f1ca0f8d"

[ -f "${WERKZEUG_PATCH_34069}" ] \
    || die "Werkzeug security patch not found: ${WERKZEUG_PATCH_34069}"

ACTUAL_WERKZEUG_PATCH_34069_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_34069}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_34069_SHA256}" = "${WERKZEUG_PATCH_34069_SHA256}" ] \
    || die "Unexpected SHA256 for CVE-2024-34069 patch: ${ACTUAL_WERKZEUG_PATCH_34069_SHA256}"

if grep -q 'self.trusted_hosts = \[".localhost", "127.0.0.1"\]' \
    "${WERKZEUG_DIR}/debug/__init__.py" \
    && grep -q 'application.trusted_hosts.append(hostname)' \
    "${WERKZEUG_DIR}/serving.py"; then
    echo ">>> Werkzeug CVE-2024-34069 backport already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_34069}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_34069}"
    )
    echo ">>> Werkzeug CVE-2024-34069 backport applied."
fi

"${PYTHON}" -m py_compile \
    "${WERKZEUG_DIR}/debug/__init__.py" \
    "${WERKZEUG_DIR}/serving.py"

grep -q 'self.trusted_hosts = \[".localhost", "127.0.0.1"\]' \
    "${WERKZEUG_DIR}/debug/__init__.py" \
    || die "Werkzeug CVE-2024-34069 trusted hosts marker not found"

grep -q 'application.trusted_hosts.append(hostname)' \
    "${WERKZEUG_DIR}/serving.py" \
    || die "Werkzeug CVE-2024-34069 serving hostname marker not found"

[ "$(grep -c 'url: document.location,' \
    "${WERKZEUG_DIR}/debug/shared/debugger.js")" -eq 2 ] \
    || die "Werkzeug CVE-2024-34069 debugger.js markers not found"

echo ">>> Running CVE-2024-34069 regression test..."

"${PYTHON}" - <<'PYTEST'
from werkzeug.debug import DebuggedApplication
from werkzeug.test import Client
from werkzeug.wrappers import Response


def app(environ, start_response):
    response = Response("normal")
    return response(environ, start_response)


debug_app = DebuggedApplication(app, evalex=True)
client = Client(debug_app, Response)

bad = client.get(
    "/console",
    headers={"Host": "attacker.example"},
)

good = client.get(
    "/console",
    headers={"Host": "localhost"},
)

if bad.status_code != 400:
    raise RuntimeError(
        "CVE-2024-34069 regression: untrusted debugger Host was accepted"
    )

if good.status_code != 200:
    raise RuntimeError(
        "CVE-2024-34069 regression: trusted localhost debugger Host was rejected"
    )

print("CVE-2024-34069 DEBUGGER HOST TRUST TEST: PASS")
PYTEST

echo ">>> Werkzeug CVE-2024-34069 backport verified."

###############################################################################
# 26. Apply consolidated Werkzeug safe_join security backports
#     CVE-2024-49766, CVE-2025-66221, CVE-2026-21860,
#     CVE-2026-27199, CVE-2026-102598
###############################################################################

echo
echo "============================================================"
echo " Applying consolidated Werkzeug safe_join security backports"
echo "============================================================"

WERKZEUG_PATCH_SAFE_JOIN="${REPO_ROOT}/utils/patch-werkzeug-1.0.1/safe-join-security-backports.patch"
WERKZEUG_PATCH_SAFE_JOIN_SHA256="acca1e1741f0c0b65b2a67498fce315772b5c9a9c1d763a6bd60af0436543650"

[ -f "${WERKZEUG_PATCH_SAFE_JOIN}" ] \
    || die "Werkzeug safe_join security patch not found: ${WERKZEUG_PATCH_SAFE_JOIN}"

ACTUAL_WERKZEUG_PATCH_SAFE_JOIN_SHA256="$(
    sha256sum "${WERKZEUG_PATCH_SAFE_JOIN}" | awk '{print $1}'
)"

[ "${ACTUAL_WERKZEUG_PATCH_SAFE_JOIN_SHA256}" = "${WERKZEUG_PATCH_SAFE_JOIN_SHA256}" ] \
    || die "Unexpected SHA256 for Werkzeug safe_join security patch: ${ACTUAL_WERKZEUG_PATCH_SAFE_JOIN_SHA256}"

if grep -q 'filename.startswith("/")' \
    "${WERKZEUG_DIR}/security.py" \
    && grep -q 'part.partition(":")\[0\]' \
    "${WERKZEUG_DIR}/security.py" \
    && grep -q 'CONOUT\$' \
    "${WERKZEUG_DIR}/security.py"; then
    echo ">>> Werkzeug safe_join security backports already present."
else
    (
        cd "${WERKZEUG_DIR}"
        patch --dry-run -p1 < "${WERKZEUG_PATCH_SAFE_JOIN}" >/dev/null
        patch -p1 < "${WERKZEUG_PATCH_SAFE_JOIN}"
    )
    echo ">>> Werkzeug safe_join security backports applied."
fi

"${PYTHON}" -m py_compile "${WERKZEUG_DIR}/security.py"

echo ">>> Running consolidated Werkzeug safe_join regression test..."

"${PYTHON}" - <<'PYTEST'
import ntpath

import werkzeug.security as security
from werkzeug.security import safe_join


assert safe_join("a", "b/c") == "a/b/c"
assert safe_join("a", "../b/c") is None

# CVE-2024-49766
original_isabs = security.os.path.isabs
security.os.path.isabs = ntpath.isabs

try:
    assert safe_join("a", "//b/c") is None
finally:
    security.os.path.isabs = original_isabs

# CVE-2025-66221, CVE-2026-21860,
# CVE-2026-27199, CVE-2026-102598
original_name = security.os.name
security.os.name = "nt"

try:
    blocked = [
        "CON",
        "CON.txt",
        "CON.txt.html",
        "CON  ",
        "CON . txt",
        "CONIN$",
        "CONOUT$",
        "COM1",
        "LPT9",
        u"COM\u00b9",
        u"LPT\u00b3",
        "b/CON",
        "CON:",
        "CON::$DATA",
        "b/CON:",
    ]

    for value in blocked:
        result = safe_join("a", value)

        if result is not None:
            raise RuntimeError(
                "Werkzeug safe_join regression: unsafe path accepted: %r => %r"
                % (value, result)
            )
finally:
    security.os.name = original_name

print("WERKZEUG SAFE_JOIN CONSOLIDATED REGRESSION TEST: PASS")
PYTEST

echo ">>> Werkzeug safe_join security backports verified."

###############################################################################
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
# 31. Verify critical packages
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
# 32. Apply PADIT cryptography compatibility patch
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
# 33. Apply PADIT socketIO client patch if present
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
# 34. Basic Python runtime validation
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
# 35. PADIT server import validation
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
# 36. PADIT server component validation
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
# 37. Socket.IO validation
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
# 38. PADIT crypto functional test
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
# 39. Generate runtime inventory
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
# 40. Final status
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
