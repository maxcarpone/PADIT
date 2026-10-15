#!/bin/bash
set -euo pipefail

# PADIT Unix agent - Debian 12 autonomous product builder
# Pilot package: build and inspect only; no installation.
# The validated runtime is copied, never modified in place.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${PADIT_UNIX_PRODUCT_RUNTIME_ROOT:-/tmp/padit-agent-unix-validation-runtime-r5}"
OUTPUT="${PADIT_UNIX_PRODUCT_OUTPUT:-/tmp/padit-agent-unix-products}"
VERSION="1.8.3.7494+unixpilot1"
PACKAGE="tis-waptagent"
DEB="${PACKAGE}_${VERSION}_amd64.deb"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

for tool in realpath rsync dpkg-deb python3 mktemp; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Missing tool: $tool"
done

[ "$(dpkg --print-architecture)" = "amd64" ] ||
    die "Only amd64 is currently supported"

case "$RUNTIME" in
    /*) ;;
    *) die "Runtime path must be absolute" ;;
esac

case "$OUTPUT" in
    /*) ;;
    *) die "Output path must be absolute" ;;
esac

RUNTIME="$(realpath -m -- "$RUNTIME")"
OUTPUT="$(realpath -m -- "$OUTPUT")"

# Protect the Git repository and prevent source/output overlaps.
case "$OUTPUT/" in
    "$REPO_ROOT/"*|"/") die "Unsafe output location" ;;
esac

case "$REPO_ROOT/" in
    "$OUTPUT/"*) die "Output overlaps source repository" ;;
esac

case "$OUTPUT/" in
    "$RUNTIME/"*) die "Output overlaps runtime" ;;
esac

case "$RUNTIME/" in
    "$OUTPUT/"*) die "Runtime overlaps output" ;;
esac

[ -x "$RUNTIME/bin/python" ] ||
    die "Missing autonomous Python runtime"

[ -f "$REPO_ROOT/waptservice/service.py" ] ||
    die "Missing WAPT service source"

[ -f "$REPO_ROOT/waptservice/scripts/waptservice.service" ] ||
    die "Missing systemd service definition"

[ ! -e "$OUTPUT/$DEB" ] && [ ! -L "$OUTPUT/$DEB" ] ||
    die "Package already exists: $OUTPUT/$DEB"

STAGING="$(mktemp -d /tmp/padit-unix-product-stage-XXXXXXXX)"
trap 'rm -rf -- "$STAGING"' EXIT

PKGROOT="$STAGING/package"
PAYLOAD="$PKGROOT/opt/wapt"

mkdir -p \
    "$PAYLOAD" \
    "$PKGROOT/DEBIAN" \
    "$PKGROOT/usr/bin" \
    "$PKGROOT/usr/lib/systemd/system"

echo ">>> Copying validated autonomous runtime"

cp -a -- "$RUNTIME/." "$PAYLOAD/"

echo ">>> Adding PADIT application sources"

SOURCES=(
    wapt-get.py
    waptcrypto.py
    waptutils.py
    common.py
    custom_zip.py
    waptpackage.py
    setuphelpers.py
    setuphelpers_linux.py
    setuphelpers_unix.py
    runwaptservice.sh
    wapt-get.sh
)

for source in "${SOURCES[@]}"; do
    [ -f "$REPO_ROOT/$source" ] ||
        die "Missing source: $source"
    cp -a -- "$REPO_ROOT/$source" "$PAYLOAD/"
done

printf '%s\n' "$VERSION" > "$PAYLOAD/version-full"

mkdir -p "$PAYLOAD/templates" "$PAYLOAD/waptservice"

rsync -a \
    --exclude='*.pyc' \
    --exclude='*.pem' \
    --exclude='*.key' \
    --exclude='*.crt' \
    "$REPO_ROOT/templates/" "$PAYLOAD/templates/"

rsync -a \
    --exclude='/deb/' \
    --exclude='/rpm/' \
    --exclude='/pkg/' \
    --exclude='/ssl/' \
    --exclude='*.pyc' \
    --exclude='*.pem' \
    --exclude='*.key' \
    --exclude='*.crt' \
    "$REPO_ROOT/waptservice/" "$PAYLOAD/waptservice/"

# Legacy compatibility module, if present.
if [ -f "$REPO_ROOT/lib/site-packages/dialog.py" ]; then
    cp -a -- "$REPO_ROOT/lib/site-packages/dialog.py" \
        "$PAYLOAD/lib/python2.7/site-packages/"
fi

echo ">>> Relocating runtime command shebangs"

python3 - "$PAYLOAD/bin" "$RUNTIME" <<'PY'
import os
import stat
import sys

bindir, old_root = sys.argv[1:]
old_prefix = old_root.encode('utf-8')
new_prefix = b'/opt/wapt'
updated = 0

for name in os.listdir(bindir):
    path = os.path.join(bindir, name)
    if not stat.S_ISREG(os.lstat(path).st_mode):
        continue
    with open(path, 'rb') as f:
        first = f.readline()
        if not first.startswith(b'#!') or old_prefix not in first:
            continue
        rest = f.read()
    with open(path, 'wb') as f:
        f.write(first.replace(old_prefix, new_prefix) + rest)
    updated += 1

print("[PASS] Relocated %d command shebangs" % updated)
PY

chmod 755 \
    "$PAYLOAD/runwaptservice.sh" \
    "$PAYLOAD/wapt-get.sh"

ln -s /opt/wapt/wapt-get.sh "$PKGROOT/usr/bin/wapt-get"
ln -s /opt/wapt/runwaptservice.sh "$PKGROOT/usr/bin/waptservice"
ln -s /opt/wapt/bin/python "$PKGROOT/usr/bin/waptpython"

cp -a \
    "$REPO_ROOT/waptservice/scripts/waptservice.service" \
    "$PKGROOT/usr/lib/systemd/system/waptservice.service"

echo ">>> Writing Debian package metadata"

cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Section: admin
Priority: optional
Architecture: amd64
Maintainer: PADIT Community
Conflicts: tis-waptserver
Description: PADIT autonomous WAPT agent for Debian 12
 Python 2.7 runtime and PADIT application bundled.
 Pilot package: systemd service is not enabled automatically.
EOF

cat > "$PKGROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    configure)
        # Keep configuration and existing data untouched.
        # Do not start or enable the service during pilot validation.
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload || true
        fi
        echo "PADIT agent installed; service not automatically enabled."
        ;;
esac

exit 0
EOF

cat > "$PKGROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

exit 0
EOF

chmod 755 \
    "$PKGROOT/DEBIAN/postinst" \
    "$PKGROOT/DEBIAN/postrm"

echo ">>> Validating staged Python and application imports"

env -u PYTHONHOME -u PYTHONPATH \
    PADIT_STAGE_ROOT="$PAYLOAD" \
    "$PAYLOAD/bin/python" -E -s - <<'PY'
import os
import sys
import ssl
import ldap
import cryptography

root = os.environ['PADIT_STAGE_ROOT']
assert sys.prefix == root, (sys.prefix, root)

sys.path.insert(0, root)

import setuphelpers_linux

assert setuphelpers_linux.apt is None
assert ldap.__version__ == '3.3.1'
assert cryptography.__version__ == '3.3.2'

print("[PASS] Staged autonomous Python and application imports")
print("[PASS] OpenSSL:", ssl.OPENSSL_VERSION)
PY

echo ">>> Building Debian archive"

mkdir -p -- "$OUTPUT"

dpkg-deb --build --root-owner-group \
    "$PKGROOT" "$OUTPUT/$DEB"

echo
echo "[PASS] Debian pilot package created:"
echo "$OUTPUT/$DEB"
echo
echo "IMPORTANT: package not installed; functional acceptance pending."
