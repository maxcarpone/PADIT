#!/usr/bin/env bash
set -euo pipefail

# PADIT - Isolated OpenSSL 3.5.9 builder for Debian Bookworm.
# Never replaces the system OpenSSL or an existing installation.

VERSION="3.5.9"
EXPECTED_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"

# Paths may be configured by the Environment/Runtime orchestrator.
# Defaults do not depend on the historical laboratory.
LAB="${PADIT_BUILD_BASE:-/tmp/padit-build}"

ARCHIVE="${PADIT_OPENSSL_ARCHIVE:-${LAB}/sources/openssl-${VERSION}.tar.gz}"
BUILD_ROOT="${PADIT_OPENSSL_BUILD_ROOT:-${LAB}/work/openssl-${VERSION}-builder}"
PREFIX="${PADIT_OPENSSL_PREFIX:-${LAB}/openssl-${VERSION}-builder}"

RUN_TESTS="${PADIT_OPENSSL_RUN_TESTS:-1}"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

echo "=== PADIT OPENSSL ${VERSION} BUILDER ==="

[ "$(id -u)" -eq 0 ] || die "Root privileges required"
[ "$RUN_TESTS" = 0 ] || [ "$RUN_TESTS" = 1 ] ||
    die "PADIT_OPENSSL_RUN_TESTS must be 0 or 1"

# Canonicalize destinations and reject overlaps with the Git checkout.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for candidate in "$PREFIX" "$BUILD_ROOT"; do
    case "$candidate" in
        /*) ;;
        *) die "Absolute path required: $candidate" ;;
    esac

    canonical="$(realpath -m -- "$candidate")"

    case "$canonical/" in
        "$REPO_ROOT/"*|"/")
            die "Unsafe destination: $canonical" ;;
    esac

    case "$REPO_ROOT/" in
        "$canonical/"*)
            die "Destination contains repository: $canonical" ;;
    esac
done

PREFIX="$(realpath -m -- "$PREFIX")"
BUILD_ROOT="$(realpath -m -- "$BUILD_ROOT")"

case "$PREFIX/" in
    "$BUILD_ROOT/"*) die "Overlapping build/install paths" ;;
esac

case "$BUILD_ROOT/" in
    "$PREFIX/"*) die "Overlapping build/install paths" ;;
esac

case "$PREFIX:$BUILD_ROOT" in
    *..*) die "Parent-directory references are forbidden" ;;
esac

[ "$PREFIX" != "$BUILD_ROOT" ] ||
    die "Build and installation paths must differ"

[ ! -e "$PREFIX" ] && [ ! -L "$PREFIX" ] ||
    die "Installation already exists: $PREFIX"

[ ! -e "$BUILD_ROOT" ] && [ ! -L "$BUILD_ROOT" ] ||
    die "Build directory already exists: $BUILD_ROOT"

if [ ! -f "$ARCHIVE" ]; then
    echo ">>> Downloading verified OpenSSL source..."
    mkdir -p "$(dirname "$ARCHIVE")"
    curl -fL --retry 3 \
        "https://github.com/openssl/openssl/releases/download/openssl-${VERSION}/openssl-${VERSION}.tar.gz" \
        -o "$ARCHIVE" ||
        die "Cannot download OpenSSL source"
fi

echo "=== VERIFY SOURCE SHA256 ==="

echo "$EXPECTED_SHA256  $ARCHIVE" | sha256sum -c -

echo "=== VERIFY BUILD TOOLS ==="

for tool in gcc make perl tar sha256sum; do
    command -v "$tool" >/dev/null ||
        die "Missing build tool: $tool"
done

echo "=== EXTRACT SOURCES ==="

mkdir -p "$BUILD_ROOT"

tar -xzf "$ARCHIVE" -C "$BUILD_ROOT"

SOURCE="$BUILD_ROOT/openssl-$VERSION"

[ -f "$SOURCE/Configure" ] ||
    die "OpenSSL source tree missing"

cd "$SOURCE"

echo "=== CONFIGURE OPENSSL ==="

./config shared \
    "--prefix=$PREFIX" \
    "--openssldir=$PREFIX/ssl"

echo "=== BUILD OPENSSL ==="

make -j"$(nproc)"

if [ "$RUN_TESTS" = 1 ]; then
    echo "=== OPENSSL NATIVE TEST SUITE ==="
    make test
else
    echo "[WARN] Native tests explicitly disabled"
fi

echo "=== INSTALL ISOLATED OPENSSL ==="

make install_sw

LIBDIR="$PREFIX/lib64"

[ -f "$LIBDIR/libcrypto.so.3" ] ||
    die "libcrypto.so.3 missing"

[ -f "$LIBDIR/libssl.so.3" ] ||
    die "libssl.so.3 missing"

echo "=== VERIFY INSTALLED VERSION ==="

env LD_LIBRARY_PATH="$LIBDIR" \
    "$PREFIX/bin/openssl" version -a

ACTUAL="$(
    env LD_LIBRARY_PATH="$LIBDIR" \
        "$PREFIX/bin/openssl" version
)"

case "$ACTUAL" in
    "OpenSSL $VERSION "*) ;;
    *) die "Unexpected OpenSSL version: $ACTUAL" ;;
esac

echo "=== VERIFY SYSTEM OPENSSL ==="

/usr/bin/openssl version

echo "=== INSTALLED LIBRARIES ==="

sha256sum \
    "$LIBDIR/libcrypto.so.3" \
    "$LIBDIR/libssl.so.3"

echo "=== PADIT OPENSSL BUILDER / PASS ==="

echo "Installation: $PREFIX"
echo "Build directory: $BUILD_ROOT"
