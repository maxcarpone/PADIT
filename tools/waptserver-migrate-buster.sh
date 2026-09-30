#!/bin/bash
set -u

SCRIPT_VERSION="1.1"
BACKUP_FORMAT_VERSION="1"
EXPECTED_DEBIAN_MAJOR="10"
EXPECTED_WAPT_PREFIX="1.8.2.7393"
SOURCE_BUILD="7393"
TARGET_SERVER_PACKAGE="tis-waptserver"
TARGET_SETUP_PACKAGE="tis-waptsetup"
EXPECTED_TARGET_DB_VERSION='"1.8.3.0"'

# The manifest and both .deb files must be obtained from the same trusted release.
# Never execute or source the manifest: parse its declared data fields only.
load_target() {
    local manifest="$1" line key value
    local -A fields=()
    [ -f "$manifest" ] && [ -r "$manifest" ] || {
        echo "[BLOCK] Release manifest unavailable: $manifest"
        return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        [[ "$line" =~ ^([a-z0-9_]+)=([A-Za-z0-9.+_-]+)$ ]] || {
            echo "[BLOCK] Invalid manifest line"
            return 1
        }
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        case "$key" in
            target_build|server_version|server_arch|server_sha256|setup_version|setup_arch|setup_sha256|root_sha256|windows_setup_sha256|windows_deploy_sha256) ;;
            *) echo "[BLOCK] Unknown manifest field: $key"; return 1 ;;
        esac
        [ -z "${fields[$key]+x}" ] || {
            echo "[BLOCK] Duplicate manifest field: $key"
            return 1
        }
        fields[$key]="$value"
    done < "$manifest"
    for key in target_build server_version server_arch server_sha256 setup_version setup_arch setup_sha256 root_sha256 windows_setup_sha256 windows_deploy_sha256; do
        [ -n "${fields[$key]:-}" ] || {
            echo "[BLOCK] Missing manifest field: $key"
            return 1
        }
    done
    [[ "${fields[target_build]}" =~ ^[0-9]+$ ]] || return 1
    [[ "${fields[server_version]}" == 1.8.3.*-debian-10-amd64 ]] || return 1
    [[ "${fields[server_version]}" == "1.8.3.${fields[target_build]}-"* ]] || return 1
    [[ "${fields[setup_version]}" == "1.8.3.${fields[target_build]}" || \
       "${fields[setup_version]}" == "1.8.3.${fields[target_build]}-"* ]] || return 1
    [[ "${fields[server_arch]}" == amd64 ]] || return 1
    [[ "${fields[setup_arch]}" == all || "${fields[setup_arch]}" == amd64 ]] || return 1
    for key in server_sha256 setup_sha256 root_sha256 windows_setup_sha256 windows_deploy_sha256; do
        [[ "${fields[$key]}" =~ ^[[:xdigit:]]{64}$ ]] || {
            echo "[BLOCK] Invalid SHA256: $key"
            return 1
        }
    done
    TARGET_BUILD="${fields[target_build]}"
    TARGET_SERVER_VERSION="${fields[server_version]}"
    TARGET_SERVER_ARCH="${fields[server_arch]}"
    TARGET_SERVER_SHA256="${fields[server_sha256],,}"
    TARGET_SETUP_VERSION="${fields[setup_version]}"
    TARGET_SETUP_ARCH="${fields[setup_arch]}"
    TARGET_SETUP_SHA256="${fields[setup_sha256],,}"
    TARGET_ROOT_SHA256="${fields[root_sha256],,}"
    TARGET_WINDOWS_SETUP_SHA256="${fields[windows_setup_sha256],,}"
    TARGET_WINDOWS_DEPLOY_SHA256="${fields[windows_deploy_sha256],,}"
    RELEASE_MANIFEST_SHA256="$(sha256sum "$manifest" | awk '{print $1}')"
    return 0
}

WAPT_CONFIG="/opt/wapt/conf/waptserver.ini"
BACKUP_ROOT="/var/www/wapt-backups"

ok()    { echo "[ OK ] $*"; }
warn()  { echo "[WARN] $*"; }
block() { echo "[BLOCK] $*"; BLOCKING=$((BLOCKING + 1)); }

BLOCKING=0
WAPT_DB_COUNT=0
WAPT_DB_PORT=""
WAPT_DB_VERSION=""
DB_VERSION=""
CONFIG_SHA256=""

declare -A DB_COUNTS

precheck() {
    BLOCKING=0

    echo "WAPT Server Buster migration precheck v${SCRIPT_VERSION}"
    echo "====================================================="
    echo

    if [ "$(id -u)" -eq 0 ]; then
        ok "Running as root"
    else
        block "Must be run as root"
    fi

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        echo "OS: ${PRETTY_NAME:-unknown}"
        if [ "${VERSION_ID:-}" = "$EXPECTED_DEBIAN_MAJOR" ]; then
            ok "Debian ${EXPECTED_DEBIAN_MAJOR}"
        else
            block "Expected Debian ${EXPECTED_DEBIAN_MAJOR}, found ${VERSION_ID:-unknown}"
        fi
    else
        block "/etc/os-release unavailable"
    fi

    WAPT_VERSION="$(dpkg-query -W -f='${Version}' tis-waptserver 2>/dev/null || true)"
    echo "tis-waptserver: ${WAPT_VERSION:-not installed}"

    case "$WAPT_VERSION" in
        ${EXPECTED_WAPT_PREFIX}*)
            ok "Expected WAPT 7393 source version"
            ;;
        "")
            block "tis-waptserver is not installed"
            ;;
        *)
            block "Unexpected WAPT server version: $WAPT_VERSION"
            ;;
    esac

    if [ -x /opt/wapt/bin/python ]; then
        PYTHON_VERSION="$(/opt/wapt/bin/python --version 2>&1)"
        echo "WAPT Python: $PYTHON_VERSION"
    else
        PYTHON_VERSION=""
        block "/opt/wapt/bin/python missing"
    fi

    for service in waptserver wapttasks nginx; do
        if systemctl is-active --quiet "$service"; then
            ok "Service $service active"
        else
            block "Service $service is not active"
        fi
    done

    if [ -f "$WAPT_CONFIG" ]; then
        ok "Configuration found: $WAPT_CONFIG"
        CONFIG_SHA256="$(sha256sum "$WAPT_CONFIG" | awk '{print $1}')"
        echo "Config SHA256: $CONFIG_SHA256"
    else
        block "Configuration missing: $WAPT_CONFIG"
    fi

    for cmd in pg_dump pg_restore psql sha256sum tar openssl apt-get \
               dpkg-query dpkg-deb runuser stat df hostname; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "Tool available: $cmd"
        else
            block "Required tool missing: $cmd"
        fi
    done

    if command -v pg_lsclusters >/dev/null 2>&1; then
        ok "Tool available: pg_lsclusters"

        WAPT_DB_COUNT=0
        WAPT_DB_PORT=""
        WAPT_DB_VERSION=""

        while read -r pg_version pg_cluster pg_port pg_status pg_owner rest; do
            [ "$pg_status" = "online" ] || continue

            if runuser -u postgres -- psql -p "$pg_port" -Atc \
                "SELECT 1 FROM pg_database WHERE datname='wapt';" 2>/dev/null \
                | grep -qx '1'; then
                WAPT_DB_COUNT=$((WAPT_DB_COUNT + 1))
                WAPT_DB_PORT="$pg_port"
                WAPT_DB_VERSION="$pg_version"
            fi
        done < <(pg_lsclusters --no-header)

        case "$WAPT_DB_COUNT" in
            1)
                ok "WAPT database found on PostgreSQL ${WAPT_DB_VERSION}, port ${WAPT_DB_PORT}"
                ;;
            0)
                block "No WAPT database found on any online PostgreSQL cluster"
                ;;
            *)
                block "WAPT database found on multiple PostgreSQL clusters"
                ;;
        esac
    else
        block "Required tool missing: pg_lsclusters"
    fi

    if [ "$WAPT_DB_COUNT" -eq 1 ]; then
        DB_VERSION="$(runuser -u postgres -- psql -p "$WAPT_DB_PORT" -d wapt -Atc \
            "SELECT value::text FROM serverattribs WHERE key='db_version';" \
            2>/dev/null || true)"

        if [ "$DB_VERSION" = '"1.8.2.1"' ]; then
            ok "WAPT database schema version: ${DB_VERSION}"
        elif [ -z "$DB_VERSION" ]; then
            block "Unable to read WAPT database schema version"
        else
            block "Unexpected WAPT database schema version: ${DB_VERSION}"
        fi

        echo "Database baseline:"
        for table in \
            hostgroups \
            hostpackagesstatus \
            hosts \
            hostsoftwares \
            packages \
            waptusers
        do
            count="$(runuser -u postgres -- psql -p "$WAPT_DB_PORT" -d wapt -Atc \
                "SELECT count(*) FROM ${table};" 2>/dev/null || true)"

            if [[ "$count" =~ ^[0-9]+$ ]]; then
                DB_COUNTS["$table"]="$count"
                echo "  ${table}=${count}"
            else
                block "Unable to count table: ${table}"
            fi
        done
    fi

    echo
    echo "====================================================="
    if [ "$BLOCKING" -eq 0 ]; then
        echo "PRECHECK RESULT: PASS"
        return 0
    else
        echo "PRECHECK RESULT: BLOCKED ($BLOCKING blocking issue(s))"
        return 1
    fi
}

backup() {
    precheck || {
        echo
        echo "BACKUP RESULT: BLOCKED (precheck failed)"
        return 1
    }

    echo
    echo "WAPT Server Buster migration backup v${SCRIPT_VERSION}"
    echo "====================================================="

    TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
    HOST="$(hostname)"
    BACKUP_DIR="${BACKUP_ROOT}/migration-${SOURCE_BUILD}-${TARGET_BUILD}-${TIMESTAMP}"
    DB_DUMP="${BACKUP_DIR}/wapt-${HOST}.dump"
    CONFIG_ARCHIVE="${BACKUP_DIR}/wapt-config-${HOST}.tar.gz"
    MANIFEST="${BACKUP_DIR}/manifest.txt"
    CHECKSUMS="${BACKUP_DIR}/SHA256SUMS"

    # Conservative space requirement:
    # twice the active PostgreSQL cluster size + 1 GiB.
    PG_DATA_DIR="$(pg_lsclusters --no-header | awk \
        -v port="$WAPT_DB_PORT" '$3 == port {print $6; exit}')"

    if [ -z "$PG_DATA_DIR" ] || [ ! -d "$PG_DATA_DIR" ]; then
        block "Unable to determine PostgreSQL data directory"
        echo "BACKUP RESULT: BLOCKED"
        return 1
    fi

    PG_SIZE_BYTES="$(du -sb "$PG_DATA_DIR" 2>/dev/null | awk '{print $1}')"
    FREE_BYTES="$(df -B1 --output=avail "$BACKUP_ROOT" 2>/dev/null | tail -1 | tr -d ' ')"

    # BACKUP_ROOT may not exist yet; inspect /var/www in that case.
    if ! [[ "$FREE_BYTES" =~ ^[0-9]+$ ]]; then
        FREE_BYTES="$(df -B1 --output=avail /var/www | tail -1 | tr -d ' ')"
    fi

    if ! [[ "$PG_SIZE_BYTES" =~ ^[0-9]+$ ]] || \
       ! [[ "$FREE_BYTES" =~ ^[0-9]+$ ]]; then
        block "Unable to determine backup space requirements"
        echo "BACKUP RESULT: BLOCKED"
        return 1
    fi

    REQUIRED_BYTES=$((PG_SIZE_BYTES * 2 + 1073741824))

    echo "PostgreSQL data size: ${PG_SIZE_BYTES} bytes"
    echo "Backup filesystem free: ${FREE_BYTES} bytes"
    echo "Required safety space: ${REQUIRED_BYTES} bytes"

    if [ "$FREE_BYTES" -lt "$REQUIRED_BYTES" ]; then
        block "Insufficient free space for verified backup"
        echo "BACKUP RESULT: BLOCKED"
        return 1
    fi
    ok "Sufficient free space"

    mkdir -p "$BACKUP_DIR" || {
        block "Unable to create $BACKUP_DIR"
        return 1
    }
    chmod 700 "$BACKUP_DIR"

    echo
    echo "Creating PostgreSQL custom-format dump..."
    if (cd /tmp && runuser -u postgres -- pg_dump -p "$WAPT_DB_PORT" -Fc -d wapt) > "$DB_DUMP"; then
        ok "Database dump created"
    else
        block "Database dump failed"
        return 1
    fi

    if [ ! -s "$DB_DUMP" ]; then
        block "Database dump is empty"
        return 1
    fi

    if pg_restore -l "$DB_DUMP" >/dev/null 2>&1; then
        ok "Database dump verified with pg_restore -l"
    else
        block "Database dump verification failed"
        return 1
    fi

    echo
    echo "Creating configuration archive..."

    BACKUP_PATHS=()
    for path in \
        /opt/wapt/conf \
        /opt/wapt/waptserver/ssl \
        /etc/nginx/sites-available/wapt.conf \
        /var/www/ssl
    do
        if [ -e "$path" ]; then
            BACKUP_PATHS+=("${path#/}")
        else
            warn "Optional backup path missing: $path"
        fi
    done

    if [ "${#BACKUP_PATHS[@]}" -eq 0 ]; then
        block "No configuration paths available for backup"
        return 1
    fi

    if tar -C / -czf "$CONFIG_ARCHIVE" "${BACKUP_PATHS[@]}"; then
        ok "Configuration archive created"
    else
        block "Configuration archive failed"
        return 1
    fi

    if tar -tzf "$CONFIG_ARCHIVE" >/dev/null 2>&1; then
        ok "Configuration archive verified"
    else
        block "Configuration archive verification failed"
        return 1
    fi

    {
        echo "script_version=${SCRIPT_VERSION}"
        echo "backup_format_version=${BACKUP_FORMAT_VERSION}"
        echo "timestamp=${TIMESTAMP}"
        echo "hostname=${HOST}"
        echo "os=${PRETTY_NAME:-unknown}"
        echo "kernel=$(uname -r)"
        echo "wapt_version=${WAPT_VERSION}"
        echo "source_build=${SOURCE_BUILD}"
        echo "target_build=${TARGET_BUILD}"
        echo "release_manifest_sha256=${RELEASE_MANIFEST_SHA256}"
        echo "server_package=${TARGET_SERVER_PACKAGE}"
        echo "server_version=${TARGET_SERVER_VERSION}"
        echo "server_arch=${TARGET_SERVER_ARCH}"
        echo "server_sha256=${TARGET_SERVER_SHA256}"
        echo "setup_package=${TARGET_SETUP_PACKAGE}"
        echo "setup_version=${TARGET_SETUP_VERSION}"
        echo "setup_arch=${TARGET_SETUP_ARCH}"
        echo "setup_sha256=${TARGET_SETUP_SHA256}"
        echo "root_sha256=${TARGET_ROOT_SHA256}"
        echo "windows_setup_sha256=${TARGET_WINDOWS_SETUP_SHA256}"
        echo "windows_deploy_sha256=${TARGET_WINDOWS_DEPLOY_SHA256}"
        echo "wapt_python=${PYTHON_VERSION}"
        echo "config_path=${WAPT_CONFIG}"
        echo "config_sha256=${CONFIG_SHA256}"
        echo "postgresql_version=${WAPT_DB_VERSION}"
        echo "postgresql_port=${WAPT_DB_PORT}"
        echo "postgresql_data_dir=${PG_DATA_DIR}"
        echo "postgresql_data_size_bytes=${PG_SIZE_BYTES}"
        echo "db_version=${DB_VERSION}"
        for table in \
            hostgroups \
            hostpackagesstatus \
            hosts \
            hostsoftwares \
            packages \
            waptusers
        do
            echo "${table}=${DB_COUNTS[$table]}"
        done
    } > "$MANIFEST"

    (
        cd "$BACKUP_DIR" || exit 1
        sha256sum "$(basename "$DB_DUMP")" \
                  "$(basename "$CONFIG_ARCHIVE")" \
                  "$(basename "$MANIFEST")" > "$(basename "$CHECKSUMS")"
    ) || {
        block "Unable to generate SHA256SUMS"
        return 1
    }

    if (cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS); then
        ok "Backup checksums verified"
    else
        block "Backup checksum verification failed"
        return 1
    fi

    chmod 600 "$DB_DUMP" "$CONFIG_ARCHIVE" "$MANIFEST" "$CHECKSUMS"

    echo
    echo "Backup directory: $BACKUP_DIR"
    echo "Database dump: $(basename "$DB_DUMP")"
    echo "Configuration archive: $(basename "$CONFIG_ARCHIVE")"
    echo "Manifest: $(basename "$MANIFEST")"
    echo "Checksums: $(basename "$CHECKSUMS")"
    echo
    echo "====================================================="
    echo "BACKUP RESULT: PASS"
}

validate_one_package() {
    local deb="$1" expected_package="$2" expected_version="$3"
    local expected_arch="$4" expected_sha256="$5"
    local actual_sha256 actual_package actual_version actual_arch
    [ -f "$deb" ] && [ -r "$deb" ] || {
        block "Target package unavailable: $deb"; return 1
    }
    actual_sha256="$(sha256sum "$deb" | awk '{print $1}')"
    actual_package="$(dpkg-deb -f "$deb" Package 2>/dev/null)"
    actual_version="$(dpkg-deb -f "$deb" Version 2>/dev/null)"
    actual_arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null)"
    [ "$actual_package" = "$expected_package" ] &&
    [ "$actual_version" = "$expected_version" ] &&
    [ "$actual_arch" = "$expected_arch" ] &&
    [ "$actual_sha256" = "$expected_sha256" ] || {
        block "Package metadata or SHA256 mismatch: $deb"; return 1
    }
    ok "Target package validated: $(basename "$deb")"
}

validate_target_packages() {
    local server_deb="$1" setup_deb="$2"
    validate_one_package "$server_deb" "$TARGET_SERVER_PACKAGE" \
        "$TARGET_SERVER_VERSION" "$TARGET_SERVER_ARCH" "$TARGET_SERVER_SHA256" || return 1
    validate_one_package "$setup_deb" "$TARGET_SETUP_PACKAGE" \
        "$TARGET_SETUP_VERSION" "$TARGET_SETUP_ARCH" "$TARGET_SETUP_SHA256" || return 1
}

find_valid_backup() {
    local candidate
    local manifest

    VALID_BACKUP=""

    while IFS= read -r candidate; do
        manifest="${candidate}/manifest.txt"

        [ -f "$manifest" ] || continue
        [ -f "${candidate}/SHA256SUMS" ] || continue

        grep -Fxq "backup_format_version=${BACKUP_FORMAT_VERSION}" "$manifest" || continue
        grep -Fxq "hostname=$(hostname)" "$manifest" || continue
        grep -Fxq "source_build=${SOURCE_BUILD}" "$manifest" || continue
        grep -Fxq "target_build=${TARGET_BUILD}" "$manifest" || continue
        grep -Fxq "release_manifest_sha256=${RELEASE_MANIFEST_SHA256}" "$manifest" || continue
        grep -Fxq "server_package=${TARGET_SERVER_PACKAGE}" "$manifest" || continue
        grep -Fxq "server_version=${TARGET_SERVER_VERSION}" "$manifest" || continue
        grep -Fxq "server_arch=${TARGET_SERVER_ARCH}" "$manifest" || continue
        grep -Fxq "server_sha256=${TARGET_SERVER_SHA256}" "$manifest" || continue
        grep -Fxq "setup_package=${TARGET_SETUP_PACKAGE}" "$manifest" || continue
        grep -Fxq "setup_version=${TARGET_SETUP_VERSION}" "$manifest" || continue
        grep -Fxq "setup_arch=${TARGET_SETUP_ARCH}" "$manifest" || continue
        grep -Fxq "setup_sha256=${TARGET_SETUP_SHA256}" "$manifest" || continue
        grep -Fxq "root_sha256=${TARGET_ROOT_SHA256}" "$manifest" || continue
        grep -Fxq "windows_setup_sha256=${TARGET_WINDOWS_SETUP_SHA256}" "$manifest" || continue
        grep -Fxq "windows_deploy_sha256=${TARGET_WINDOWS_DEPLOY_SHA256}" "$manifest" || continue

        [ -f "$WAPT_CONFIG" ] || continue

        local current_config_sha256
        current_config_sha256="$(sha256sum "$WAPT_CONFIG" | awk '{print $1}')"

        grep -Fxq "config_sha256=${current_config_sha256}" "$manifest" || continue

        if (cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
            VALID_BACKUP="$candidate"
            return 0
        fi
    done < <(
        find "$BACKUP_ROOT" -maxdepth 1 -type d \
            -name "migration-${SOURCE_BUILD}-${TARGET_BUILD}-*" \
            -print 2>/dev/null | sort -r
    )

    return 1
}

postcheck_upgrade() {
    local expected_config_sha256="$1"
    local expected_db_version="$2"
    local failures=0
    local installed_version
    local config_sha256_after
    local db_version_after

    echo
    echo "WAPT Server post-upgrade check"
    echo "====================================================="

    local package expected_version installed_status
    for package in "$TARGET_SERVER_PACKAGE" "$TARGET_SETUP_PACKAGE"; do
        if [ "$package" = "$TARGET_SERVER_PACKAGE" ]; then
            expected_version="$TARGET_SERVER_VERSION"
        else
            expected_version="$TARGET_SETUP_VERSION"
        fi
        installed_version="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
        installed_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
        if [ "$installed_version" = "$expected_version" ] &&
           [ "$installed_status" = 'install ok installed' ]; then
            ok "$package installed: $installed_version"
        else
            block "$package version/status unexpected: ${installed_version:-missing} / ${installed_status:-missing}"
            failures=$((failures + 1))
        fi
    done

    local public_root="/var/www/wapt/Thouet-Software-Signing-Root-CA.cer"
    local published_root_sha256 published
    if [ -f "$public_root" ]; then
        published_root_sha256="$(sha256sum "$public_root" | awk '{print $1}')"
        if [ "$published_root_sha256" = "$TARGET_ROOT_SHA256" ]; then
            ok "Published Authenticode Root CA SHA256 verified"
        else
            block "Published Authenticode Root CA SHA256 mismatch"
            failures=$((failures + 1))
        fi
    else
        block "Published Authenticode Root CA missing: $public_root"
        failures=$((failures + 1))
    fi
    local expected_published_sha256 actual_published_sha256
    for published in /var/www/wapt/waptsetup-tis.exe /var/www/wapt/waptdeploy.exe; do
        if [ "$published" = /var/www/wapt/waptsetup-tis.exe ]; then
            expected_published_sha256="$TARGET_WINDOWS_SETUP_SHA256"
        else
            expected_published_sha256="$TARGET_WINDOWS_DEPLOY_SHA256"
        fi
        if [ -s "$published" ]; then
            actual_published_sha256="$(sha256sum "$published" | awk '{print $1}')"
        else
            actual_published_sha256=""
        fi
        if [ "$actual_published_sha256" = "$expected_published_sha256" ]; then
            ok "Published SHA256 verified: $published"
        else
            block "Published file missing or SHA256 mismatch: $published"
            failures=$((failures + 1))
        fi
    done

    if [ -f "$WAPT_CONFIG" ]; then
        config_sha256_after="$(sha256sum "$WAPT_CONFIG" | awk '{print $1}')"
        if [ "$config_sha256_after" = "$expected_config_sha256" ]; then
            ok "WAPT configuration preserved"
        else
            block "WAPT configuration changed during upgrade"
            failures=$((failures + 1))
        fi
    else
        block "WAPT configuration missing after upgrade"
        failures=$((failures + 1))
    fi

    for service in waptserver wapttasks nginx; do
        if systemctl is-active --quiet "$service"; then
            ok "Service $service active"
        else
            block "Service $service inactive"
            failures=$((failures + 1))
        fi
    done

    db_version_after="$(runuser -u postgres -- psql \
        -p "$WAPT_DB_PORT" -d wapt -Atc \
        "SELECT value FROM serverattribs WHERE key='db_version';" 2>/dev/null || true)"

    if [ "$db_version_after" = "$EXPECTED_TARGET_DB_VERSION" ]; then
        ok "Database schema migrated: $expected_db_version -> $db_version_after"
    else
        block "Database schema not at $EXPECTED_TARGET_DB_VERSION: ${db_version_after:-unavailable}"
        failures=$((failures + 1))
    fi

    echo "Database post-upgrade baseline:"
    for table in \
        hostgroups \
        hostpackagesstatus \
        hosts \
        hostsoftwares \
        packages \
        waptusers
    do
        local count_after

        count_after="$(runuser -u postgres -- psql \
            -p "$WAPT_DB_PORT" -d wapt -Atc \
            "SELECT count(*) FROM ${table};" 2>/dev/null || true)"

        if [ "$count_after" = "${DB_COUNTS[$table]}" ]; then
            ok "${table}=${count_after}"
        else
            block "${table}: before=${DB_COUNTS[$table]} after=${count_after:-unavailable}"
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -eq 0 ]; then
        echo "POST-UPGRADE RESULT: PASS"
        return 0
    fi

    echo "POST-UPGRADE RESULT: BLOCKED ($failures issue(s))"
    return 1
}

upgrade() {
    local server_deb="$1" setup_deb="$2"
    local config_sha256_before db_version_before

    echo "WAPT Server Buster migration upgrade v${SCRIPT_VERSION}"
    echo "====================================================="
    echo
    echo "[1/5] Running source precheck..."
    if ! precheck; then
        block "Upgrade aborted: source precheck failed"; return 1
    fi
    config_sha256_before="$CONFIG_SHA256"
    db_version_before="$DB_VERSION"

    echo "[2/5] Looking for a valid backup..."
    if ! find_valid_backup; then
        block "Upgrade aborted: no valid backup found"; return 1
    fi
    ok "Valid backup: $VALID_BACKUP"

    echo "[3/5] Validating both target packages..."
    if ! validate_target_packages "$server_deb" "$setup_deb"; then
        block "Upgrade aborted: target package validation failed"; return 1
    fi

    echo "UPGRADE VALIDATION: PASS"
    echo "Source build: ${SOURCE_BUILD}"
    echo "Target build: ${TARGET_BUILD}"
    echo "Backup: $VALID_BACKUP"
    echo "Server package: $server_deb"
    echo "Setup package: $setup_deb"
    echo "[4/5] Installing both validated target packages..."
    if ! dpkg -i "$server_deb" "$setup_deb"; then
        block "Package installation failed; inspect dpkg state before recovery"
        echo "[RECOVERY] Verified backup: $VALID_BACKUP"
        echo "[RECOVERY] Automatic rollback was NOT attempted"
        return 1
    fi

    echo "[5/5] Running post-upgrade checks..."
    if ! postcheck_upgrade "$config_sha256_before" "$db_version_before"; then
        block "Upgrade completed but post-upgrade checks failed"
        echo "[RECOVERY] Verified backup: $VALID_BACKUP"
        echo "[RECOVERY] Automatic rollback was NOT attempted"
        return 1
    fi
    echo "UPGRADE RESULT: PASS"
    echo "${SOURCE_BUILD} -> ${TARGET_BUILD}"
}

usage() {
    echo "Usage: $0 precheck"
    echo "       $0 backup <release-manifest>"
    echo "       $0 check-backup <release-manifest>"
    echo "       $0 check-package <release-manifest> <server.deb> <setup.deb>"
    echo "       $0 upgrade <release-manifest> <server.deb> <setup.deb>"
}

case "${1:-precheck}" in
    precheck)
        [ "$#" -le 1 ] || { usage; exit 2; }
        precheck
        ;;
    backup|check-backup)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        load_target "$2" || exit 1
        if [ "$1" = backup ]; then
            backup
        elif find_valid_backup; then
            echo "[ OK ] Valid backup found: $VALID_BACKUP"
        else
            echo "[BLOCK] No valid backup found"
            exit 1
        fi
        ;;
    check-package|upgrade)
        [ "$#" -eq 4 ] || { usage; exit 2; }
        load_target "$2" || exit 1
        if [ "$1" = check-package ]; then
            validate_target_packages "$3" "$4"
        else
            upgrade "$3" "$4"
        fi
        ;;
    *) usage; exit 2 ;;
esac
