#!/bin/bash
set -euo pipefail

# PADIT - Unix agent build environment preflight
# Validated target: Debian 12 Bookworm amd64
# Read-only: does not install, remove, or modify system packages.

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

pass() {
    echo "[PASS] $*"
}

[ -r /etc/os-release ] || die "Missing /etc/os-release"

. /etc/os-release

[ "${ID:-}" = "debian" ] || die "Debian required"
[ "${VERSION_ID:-}" = "12" ] || die "Debian 12 required"

ARCH="$(dpkg --print-architecture)"
[ "${ARCH}" = "amd64" ] || die "amd64 required"

pass "Debian 12 Bookworm amd64"

TOOLS=(
    gcc g++ make git curl tar patch
    pkg-config dpkg-deb openssl python3
    sha256sum awk
)

for tool in "${TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "Missing command: $tool"
    pass "Tool: $tool"
done

PACKAGES=(
    build-essential
    libssl-dev
    libffi-dev
    libldap2-dev
    libsasl2-dev
    libkrb5-dev
    zlib1g-dev
    libbz2-dev
    libsqlite3-dev
    libreadline-dev
    libncurses-dev
    libgdbm-dev
    liblzma-dev
    tk-dev
)

for package in "${PACKAGES[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    [ "${status}" = "ii " ] || die "Missing package: $package"
    pass "Package: $package"
done

pass "PADIT Unix build environment ready"
