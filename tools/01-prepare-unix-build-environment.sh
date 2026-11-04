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

# All system dependencies needed by Environment / Runtime / Build.
# Normal mode is read-only. Installation requires explicit opt-in.
PACKAGES=(
    build-essential
    gcc g++
    git curl tar patch
    pkg-config dpkg
    openssl python3
    perl binutils rsync patchelf dpkg-dev file
    coreutils ca-certificates
    libssl-dev
    libffi-dev
    libldap2-dev
    libpq-dev
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

missing=()

for package in "${PACKAGES[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    if [ "$status" != "ii " ]; then
        missing+=("$package")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "[INFO] Missing packages: ${missing[*]}"

    if [ "${PADIT_INSTALL_BUILD_DEPS:-0}" != 1 ]; then
        die "Missing dependencies; use PADIT_INSTALL_BUILD_DEPS=1 to prepare"
    fi

    [ "$(id -u)" -eq 0 ] ||
        die "Root privileges required to install dependencies"

    command -v apt-get >/dev/null ||
        die "apt-get unavailable"

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${missing[@]}"
fi

TOOLS=(
    gcc g++ make git curl tar patch
    pkg-config dpkg-deb openssl python3
    sha256sum awk realpath perl
    readelf rsync patchelf dpkg-shlibdeps file
)

for tool in "${TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "Missing command: $tool"
done

for package in "${PACKAGES[@]}"; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)"
    [ "$status" = "ii " ] ||
        die "Missing package after preparation: $package"
done

pass "All system dependencies verified"

pass "PADIT Unix build environment ready"
