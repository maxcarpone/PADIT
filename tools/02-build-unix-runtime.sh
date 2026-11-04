#!/bin/bash
set -euo pipefail

# PADIT - Autonomous Unix agent runtime build
# Public entry point 02 / Debian 12 Bookworm amd64

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RUNTIME_ROOT="${PADIT_AGENT_UNIX_RUNTIME_ROOT:-${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm}"
BUILD_ROOT="${PADIT_AGENT_UNIX_BUILD_ROOT:-/tmp/padit-python2-agent-unix-bookworm-build}"

die() {
    echo "[FAIL] $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Root privileges required"

bash "${REPO_ROOT}/tools/01-prepare-unix-build-environment.sh"

[ -f "${REPO_ROOT}/requirements-agent.txt" ] \
    || die "Missing common requirements"

[ -f "${REPO_ROOT}/requirements-agent-unix.txt" ] \
    || die "Missing Unix requirements"

# Normalize paths and resolve existing symbolic-link components.
command -v realpath >/dev/null 2>&1 || die "realpath required"

case "${RUNTIME_ROOT}" in
    /*) ;;
    *) die "Runtime path must be absolute: ${RUNTIME_ROOT}" ;;
esac

case "${BUILD_ROOT}" in
    /*) ;;
    *) die "Build path must be absolute: ${BUILD_ROOT}" ;;
esac

RUNTIME_ROOT="$(realpath -m -- "${RUNTIME_ROOT}")"
BUILD_ROOT="$(realpath -m -- "${BUILD_ROOT}")"

is_within() {
    local candidate="$1"
    local parent="$2"

    [ "${candidate}" = "${parent}" ] ||
        [[ "${candidate}" == "${parent}/"* ]]
}

protect_path() {
    local candidate="$1"
    local protected="$2"

    if is_within "${candidate}" "${protected}" ||
       is_within "${protected}" "${candidate}"; then
        die "Path overlaps protected location: ${candidate} / ${protected}"
    fi
}

# Runtime output is permitted only at the designated default path
# inside the repository; custom runtime outputs must be outside Git.
DEFAULT_RUNTIME="${REPO_ROOT}/build/python2-runtime-agent-unix-bookworm"

if [ "${RUNTIME_ROOT}" != "${DEFAULT_RUNTIME}" ]; then
    protect_path "${RUNTIME_ROOT}" "${REPO_ROOT}"
fi

# Build scratch directory must always remain outside the repository.
protect_path "${BUILD_ROOT}" "${REPO_ROOT}"

# Never overlap either output with the other.
if is_within "${RUNTIME_ROOT}" "${BUILD_ROOT}" ||
   is_within "${BUILD_ROOT}" "${RUNTIME_ROOT}"; then
    die "Runtime and build directories overlap"
fi

# Protect previously validated runtimes and server runtime.
for protected in \
    "${REPO_ROOT}/build/python2-runtime-server-bookworm" \
    /tmp/padit-agent-unix-validation-runtime-r1 \
    /tmp/padit-agent-unix-validation-runtime-r2 \
    /tmp/padit-agent-unix-validation-runtime-r3 \
    /tmp/padit-agent-unix-validation-runtime-r4 \
    /tmp/padit-agent-unix-validation-runtime-r5
do
    protect_path "${RUNTIME_ROOT}" "${protected}"
    protect_path "${BUILD_ROOT}" "${protected}"
done

[ ! -e "${RUNTIME_ROOT}" ] && [ ! -L "${RUNTIME_ROOT}" ] \
    || die "Runtime path already exists: ${RUNTIME_ROOT}"

[ ! -e "${BUILD_ROOT}" ] && [ ! -L "${BUILD_ROOT}" ] \
    || die "Build path already exists: ${BUILD_ROOT}"

echo ">>> PADIT Unix runtime build"
echo "Repository : ${REPO_ROOT}"
echo "Runtime    : ${RUNTIME_ROOT}"
echo "Build      : ${BUILD_ROOT}"

export PADIT_AGENT_UNIX_RUNTIME_ROOT="${RUNTIME_ROOT}"
export PADIT_AGENT_UNIX_BUILD_ROOT="${BUILD_ROOT}"

unset PYTHONPATH PYTHONHOME PYTHONVERBOSE
unset PIP_PREFIX PIP_TARGET PIP_USER VIRTUAL_ENV

OPENSSL_MODE="${PADIT_OPENSSL_MODE:-isolated}"

case "$OPENSSL_MODE" in
    system)
        echo "[INFO] Historical OpenSSL mode"
        ;;
    isolated)
        OPENSSL_PREFIX="${PADIT_OPENSSL_PREFIX:-${BUILD_ROOT}-openssl-prefix}"
        OPENSSL_BUILD_ROOT="${PADIT_OPENSSL_BUILD_ROOT:-${BUILD_ROOT}-openssl-build}"
        OPENSSL_ARCHIVE="${PADIT_OPENSSL_ARCHIVE:-${BUILD_ROOT}-openssl-3.5.9.tar.gz}"

        for candidate in "$OPENSSL_PREFIX" "$OPENSSL_BUILD_ROOT" "$OPENSSL_ARCHIVE"; do
            case "$candidate" in
                /*) ;;
                *) die "Absolute OpenSSL path required: $candidate" ;;
            esac
            candidate="$(realpath -m -- "$candidate")"
            protect_path "$candidate" "$REPO_ROOT"
            protect_path "$candidate" "$RUNTIME_ROOT"
            protect_path "$candidate" "$BUILD_ROOT"
        done

        protect_path "$(realpath -m -- "$OPENSSL_PREFIX")"                      "$(realpath -m -- "$OPENSSL_BUILD_ROOT")"

        [ ! -e "$OPENSSL_PREFIX" ] && [ ! -L "$OPENSSL_PREFIX" ] ||
            die "OpenSSL prefix already exists"

        [ ! -e "$OPENSSL_BUILD_ROOT" ] && [ ! -L "$OPENSSL_BUILD_ROOT" ] ||
            die "OpenSSL build directory already exists"

        env PADIT_OPENSSL_PREFIX="$OPENSSL_PREFIX" \
            PADIT_OPENSSL_BUILD_ROOT="$OPENSSL_BUILD_ROOT" \
            PADIT_OPENSSL_ARCHIVE="$OPENSSL_ARCHIVE" \
            bash "${REPO_ROOT}/tools/build-openssl-bookworm.sh"

        export PADIT_OPENSSL_PREFIX="$OPENSSL_PREFIX"
        echo "[PASS] OpenSSL 3.5.9 built"
        ;;
    *)
        die "Unsupported OpenSSL mode: $OPENSSL_MODE"
        ;;
esac

export PADIT_OPENSSL_MODE="$OPENSSL_MODE"

bash "${REPO_ROOT}/tools/build-python2-runtime-agent-unix-bookworm.sh"

echo "[PASS] PADIT Unix runtime build completed"
