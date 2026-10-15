#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="${PADIT_AGENT_UNIX_RUNTIME_ROOT:-${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm}"
BUILD_ROOT="$(mktemp -d /tmp/padit-agent-unix-crypto-build-XXXXXXXX)"

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

[ -x "${PYTHON}" ] || die "Python agent Unix absent"

# 10. Build cffi 1.15.1 from source
###############################################################################

echo
echo "============================================================"
echo " Building cffi 1.15.1 from source"
echo "============================================================"

CFFI_VERSION="1.15.1"
CFFI_BUILD_DIR="${BUILD_ROOT}/cffi-${CFFI_VERSION}-source"
CFFI_SDIST_SHA256="d400bfb9a37b1351253cb402671cea7e89bdecc294e8016a707f6d1d8ac934f9"

[ ! -e "${CFFI_BUILD_DIR}" ] || die "cffi build directory exists"
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

[ ! -e "${CRYPTOGRAPHY_BUILD_DIR}" ] || die "cryptography build directory exists"
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

###############################################################################
# PADIT legacy x509 verification compatibility
# Preserve upstream cryptography 3.3.2 x509/__init__.py unchanged.
###############################################################################

PADIT_X509_VERIFICATION_SOURCE="${REPO_ROOT}/utils/patch-cryptography/verification.py"
PADIT_X509_VERIFICATION_SHA256="be9836ac8835d4cef3d7deb47edaecb9344936d79534f84c95c4576f77a9d737"
PADIT_X509_DIR="${RUNTIME_ROOT}/lib/python2.7/site-packages/cryptography/x509"

[ -f "${PADIT_X509_VERIFICATION_SOURCE}" ] || die "PADIT x509 verification source missing"
[ -d "${PADIT_X509_DIR}" ] || die "cryptography x509 directory missing"

echo "${PADIT_X509_VERIFICATION_SHA256}  ${PADIT_X509_VERIFICATION_SOURCE}" | sha256sum -c - || die "PADIT x509 verification source checksum mismatch"

install -m 644 "${PADIT_X509_VERIFICATION_SOURCE}" "${PADIT_X509_DIR}/verification.py"

echo "${PADIT_X509_VERIFICATION_SHA256}  ${PADIT_X509_DIR}/verification.py" | sha256sum -c - || die "PADIT x509 installed module checksum mismatch"

"${PYTHON}" -m py_compile "${PADIT_X509_DIR}/verification.py"

"${PYTHON}" - <<'PYPADITX509'
from cryptography.x509 import verification
from cryptography.x509.verification import (
    CertificateVerificationContext,
    CertificateRevocationListVerificationContext,
    InvalidCertificate,
    InvalidSigningCertificate,
    InvalidCertificateRevocationList,
)

required = (
    CertificateVerificationContext,
    CertificateRevocationListVerificationContext,
    InvalidCertificate,
    InvalidSigningCertificate,
    InvalidCertificateRevocationList,
)

assert len(required) == 5
assert verification.__file__.endswith(
    "/cryptography/x509/verification.pyc"
) or verification.__file__.endswith(
    "/cryptography/x509/verification.py"
)

print("[PASS] PADIT x509 verification compatibility imports")
PYPADITX509

echo "[PASS] PADIT x509 compatibility module installed"

echo ">>> Running permanent PADIT x509 regressions..."
PADIT_X509_TEST_MODE=installed "${PYTHON}" "${REPO_ROOT}/utils/test-agent-unix-x509.py"
echo "[PASS] PADIT x509 permanent regression suite"


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

echo "[PASS] U53 - Agent Unix cffi and cryptography build"
