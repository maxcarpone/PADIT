#!/bin/bash
set -u

SCRIPT_VERSION="1.0.2"

ok()   { echo "[ OK ] $*"; }
warn() { echo "[WARN] $*" >&2; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

create_target_safety_backup() {
    SAFETY_ROOT="/var/www/padit-backups"
    SAFETY_STAMP="$(date +%Y%m%d-%H%M%S)"
    SAFETY_NAME="wapt-target-safety-${HOSTNAME:-unknown}-${SAFETY_STAMP}"
    SAFETY_WORK="$(mktemp -d "${SAFETY_ROOT}/.${SAFETY_NAME}.XXXXXX")" || \
        fail "Unable to create target safety-backup staging directory"
    SAFETY_ARCHIVE="${SAFETY_ROOT}/${SAFETY_NAME}.tar"

    chmod 0700 "$SAFETY_WORK" || fail "Unable to secure safety-backup staging directory"
    mkdir -p \
        "$SAFETY_WORK/database" \
        "$SAFETY_WORK/config" \
        "$SAFETY_WORK/metadata" \
        "$SAFETY_WORK/package-owned"
    chmod 0700 \
        "$SAFETY_WORK/database" \
        "$SAFETY_WORK/config" \
        "$SAFETY_WORK/metadata" \
        "$SAFETY_WORK/package-owned"

    echo "Creating lightweight target safety backup..."
    echo "Repository payload is intentionally NOT copied."

    (cd / && runuser -u postgres -- \
        pg_dump -p "$TARGET_PG_PORT" -Fc wapt) > "$SAFETY_WORK/database/wapt.dump" || \
        fail "Target safety database dump failed"
    [ -s "$SAFETY_WORK/database/wapt.dump" ] || fail "Target safety database dump is empty"
    pg_restore -l "$SAFETY_WORK/database/wapt.dump" >/dev/null 2>&1 || \
        fail "Target safety database dump is not readable"

    if [ -d /opt/wapt/conf ]; then
        tar -C / -cf "$SAFETY_WORK/config/opt-wapt-conf.tar" opt/wapt/conf || \
            fail "Unable to save target /opt/wapt/conf"
    fi
    if [ -d /opt/wapt/waptserver/ssl ]; then
        tar -C / -cf "$SAFETY_WORK/config/server-tls.tar" opt/wapt/waptserver/ssl || \
            fail "Unable to save target server TLS directory"
    fi
    if [ -f /etc/nginx/sites-available/wapt.conf ]; then
        cp -a /etc/nginx/sites-available/wapt.conf "$SAFETY_WORK/config/nginx-wapt.conf" || \
            fail "Unable to save target nginx WAPT configuration"
    elif [ -f /etc/nginx/sites-enabled/wapt.conf ]; then
        cp -a /etc/nginx/sites-enabled/wapt.conf "$SAFETY_WORK/config/nginx-wapt.conf" || \
            fail "Unable to save target nginx WAPT configuration"
    fi

    for f in /var/www/wapt/waptsetup-tis.exe /var/www/wapt/waptdeploy.exe /var/www/wapt/Thouet-Software-Signing-Root-CA.cer; do
        if [ -f "$f" ]; then
            cp -a "$f" "$SAFETY_WORK/package-owned/" || \
                fail "Unable to save target package-owned artifact: $f"
        fi
    done

    {
        echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "hostname=${HOSTNAME:-unknown}"
        echo "debian=${TARGET_DEBIAN}"
        echo "waptserver=${TARGET_WAPT}"
        echo "waptsetup=${TARGET_SETUP}"
        echo "postgresql=${TARGET_PG_VERSION}"
        echo "pg_cluster=${TARGET_PG_MAJOR}/${TARGET_PG_CLUSTER}"
        echo "pg_port=${TARGET_PG_PORT}"
        echo "db_owner=${TARGET_DB_OWNER}"
        echo "db_marker=${TARGET_DB_MARKER}"
        echo "repository_payload_copied=no"
    } > "$SAFETY_WORK/metadata/target.txt"

    if [ -d /var/www/wapt ]; then
        find /var/www/wapt -type f \
            -printf '%m|%u|%g|%s|%p\n' | sort \
            > "$SAFETY_WORK/metadata/repository-inventory.txt" || \
            fail "Unable to inventory target repository"
    else
        : > "$SAFETY_WORK/metadata/repository-inventory.txt"
    fi

    find "$SAFETY_WORK" -type d -exec chmod 0700 {} + || \
        fail "Unable to secure safety-backup directories"
    find "$SAFETY_WORK" -type f -exec chmod 0600 {} + || \
        fail "Unable to secure safety-backup files"

    tar -C "$SAFETY_ROOT" -cf "$SAFETY_ARCHIVE" "$(basename "$SAFETY_WORK")" || \
        fail "Unable to create target safety-backup archive"
    chmod 0600 "$SAFETY_ARCHIVE" || fail "Unable to secure target safety-backup archive"

    tar -tf "$SAFETY_ARCHIVE" >/dev/null || fail "Target safety-backup archive is not readable"
    tar -xOf "$SAFETY_ARCHIVE" "$(basename "$SAFETY_WORK")/database/wapt.dump" \
        | pg_restore -l >/dev/null 2>&1 || \
        fail "Database dump inside target safety-backup archive is not readable"

    rm -rf -- "$SAFETY_WORK"
    SAFETY_WORK=""

    ok "Target safety backup created and structurally validated"
    echo "Target safety backup: $SAFETY_ARCHIVE"
    echo "NOTE: repository package payload is not included in this safety backup."
}

restore_target_database() {
    echo
    echo "=================================================="
    echo "DESTRUCTIVE DATABASE PHASE"
    echo "=================================================="
    echo "The target WAPT database will now be replaced."
    echo "Safety backup retained at: $SAFETY_ARCHIVE"
    echo

    echo "Stopping WAPT application services..."
    systemctl stop waptserver || fail "Unable to stop waptserver"

    if systemctl cat wapttasks.service >/dev/null 2>&1; then
        systemctl stop wapttasks || fail "Unable to stop wapttasks"
        systemctl is-active --quiet wapttasks && fail "wapttasks is still active"
    fi

    systemctl is-active --quiet waptserver && fail "waptserver is still active"
    systemctl is-active --quiet postgresql || fail "PostgreSQL unexpectedly became inactive"
    ok "WAPT application services stopped; PostgreSQL remains active"

    echo "Replacing target database wapt on PostgreSQL ${TARGET_PG_MAJOR}/${TARGET_PG_CLUSTER}, port ${TARGET_PG_PORT}..."

    (cd / && runuser -u postgres -- \
        dropdb -p "$TARGET_PG_PORT" --if-exists wapt) || \
        fail "Unable to drop target WAPT database"

    (cd / && runuser -u postgres -- \
        createdb -p "$TARGET_PG_PORT" -O wapt -E UTF8 -T template0 wapt) || \
        fail "Unable to recreate target WAPT database"

    (cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -v ON_ERROR_STOP=1 \
        -c 'DROP SCHEMA public;') >/dev/null || \
        fail "Unable to prepare target WAPT database schema"

    cat "$BUNDLE/database/wapt.dump" | \
        (cd / && runuser -u postgres -- \
            pg_restore --exit-on-error --no-owner \
            -p "$TARGET_PG_PORT" -d wapt) || \
        fail "Database restore failed"

    ok "Logical database restore completed"

    echo "Applying targeted WAPT ownership and schema ACL corrections..."

    (cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -v ON_ERROR_STOP=1 <<'SQL'
ALTER DATABASE wapt OWNER TO wapt;
ALTER SCHEMA public OWNER TO wapt;
GRANT USAGE, CREATE ON SCHEMA public TO wapt;

DO $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'public'
    LOOP
        EXECUTE format('ALTER TABLE %I.%I OWNER TO wapt',
                       obj.schemaname, obj.tablename);
    END LOOP;

    FOR obj IN
        SELECT sequence_schema, sequence_name
        FROM information_schema.sequences
        WHERE sequence_schema = 'public'
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO wapt',
                       obj.sequence_schema, obj.sequence_name);
    END LOOP;
END
$$;
SQL
    ) >/dev/null || fail "Unable to apply WAPT ownership/schema ACL corrections"

    POST_DB_OWNER="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d postgres -Atqc \
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='wapt';" \
        2>/dev/null)" || fail "Unable to validate restored database owner"
    [ "$POST_DB_OWNER" = "wapt" ] || \
        fail "Restored WAPT database owner is not wapt: ${POST_DB_OWNER:-missing}"

    POST_SCHEMA_ACL="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT has_schema_privilege('wapt','public','USAGE')::int || '|' || has_schema_privilege('wapt','public','CREATE')::int;" \
        2>/dev/null)" || fail "Unable to validate restored schema privileges"
    [ "$POST_SCHEMA_ACL" = "1|1" ] || \
        fail "Restored public schema privileges for wapt are incomplete: ${POST_SCHEMA_ACL:-missing}"

    NON_WAPT_TABLES="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner <> 'wapt';" \
        2>/dev/null)" || fail "Unable to validate restored table ownership"
    [ "$NON_WAPT_TABLES" = "0" ] || \
        fail "Some restored public tables are not owned by wapt: $NON_WAPT_TABLES"

    NON_WAPT_SEQUENCES="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S' AND pg_get_userbyid(c.relowner) <> 'wapt';" \
        2>/dev/null)" || fail "Unable to validate restored sequence ownership"
    [ "$NON_WAPT_SEQUENCES" = "0" ] || \
        fail "Some restored public sequences are not owned by wapt: $NON_WAPT_SEQUENCES"

    POST_DB_MARKER="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT value FROM serverattribs WHERE key='db_version';" \
        2>/dev/null)" || fail "Unable to read restored WAPT database marker"
    [ -n "$POST_DB_MARKER" ] || fail "Restored WAPT database marker is empty"
    [ "$POST_DB_MARKER" = "$SOURCE_DB_MARKER" ] || \
        fail "Restored DB marker mismatch: source=$SOURCE_DB_MARKER restored=$POST_DB_MARKER"

    echo
    echo "Restored DB marker: $POST_DB_MARKER"
    echo "Essential restored table counts:"
    for table in hostgroups hostpackagesstatus hosts hostsoftwares packages waptusers; do
        count="$(cd / && runuser -u postgres -- \
            psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
            "SELECT count(*) FROM public.${table};" 2>/dev/null)" || \
            fail "Unable to count restored table: $table"
        printf '  %-20s %s\n' "$table" "$count"
    done

    ok "Restored database ownership, schema ACL, marker and essential tables validated"
}


metadata_value() {
    file="$1"
    key="$2"
    sed -n -E "s/^${key}=(.*)$/\1/p" "$file" | head -n 1
}

validate_post_database_state() {
    DB_METADATA="$BUNDLE/metadata/database.txt"
    [ -f "$DB_METADATA" ] || return 1

    POST_DB_MARKER="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT value FROM serverattribs WHERE key='db_version';" 2>/dev/null)" || return 1
    [ -n "$POST_DB_MARKER" ] || return 1
    [ "$POST_DB_MARKER" = "$SOURCE_DB_MARKER" ] || return 1

    POST_DB_OWNER="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d postgres -Atqc \
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='wapt';" 2>/dev/null)" || return 1
    [ "$POST_DB_OWNER" = "wapt" ] || return 1

    POST_SCHEMA_ACL="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT has_schema_privilege('wapt','public','USAGE')::int || '|' || has_schema_privilege('wapt','public','CREATE')::int;" 2>/dev/null)" || return 1
    [ "$POST_SCHEMA_ACL" = "1|1" ] || return 1

    NON_WAPT_TABLES="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tableowner <> 'wapt';" 2>/dev/null)" || return 1
    [ "$NON_WAPT_TABLES" = "0" ] || return 1

    NON_WAPT_SEQUENCES="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S' AND pg_get_userbyid(c.relowner) <> 'wapt';" 2>/dev/null)" || return 1
    [ "$NON_WAPT_SEQUENCES" = "0" ] || return 1

    for table in hostgroups hostpackagesstatus hosts hostsoftwares packages waptusers; do
        expected="$(metadata_value "$DB_METADATA" "$table")"
        case "$expected" in
            ''|*[!0-9]*) return 1 ;;
        esac
        actual="$(cd / && runuser -u postgres -- \
            psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
            "SELECT count(*) FROM public.${table};" 2>/dev/null)" || return 1
        [ "$actual" = "$expected" ] || return 1
    done

    return 0
}

wapt_ini_value() {
    file="$1"
    key="$2"
    sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\\1/p" "$file" | head -n 1
}

https_file_fingerprint() {
    local digest metadata
    [ -f "$1" ] || return 1
    digest="$(sha256sum < "$1")" || return 1
    metadata="$(stat -Lc '%d:%i:%a:%u:%g' -- "$1")" || return 1
    printf '%s %s\n' "$digest" "$metadata"
}

record_target_https_identity() {
    TARGET_NGINX_CONF="/etc/nginx/sites-available/wapt.conf"
    [ -f "$TARGET_NGINX_CONF" ] || fail "Target nginx WAPT configuration is missing: $TARGET_NGINX_CONF"
    TARGET_TLS_CERT="$(sed -n -E 's/^[[:space:]]*ssl_certificate[[:space:]]+"?([^";]+)"?;.*/\1/p' "$TARGET_NGINX_CONF" | head -n 1)"
    TARGET_TLS_KEY="$(sed -n -E 's/^[[:space:]]*ssl_certificate_key[[:space:]]+"?([^";]+)"?;.*/\1/p' "$TARGET_NGINX_CONF" | head -n 1)"
    [ -n "$TARGET_TLS_CERT" ] || fail "Unable to determine target nginx TLS certificate path"
    [ -n "$TARGET_TLS_KEY" ] || fail "Unable to determine target nginx TLS key path"
    TARGET_NGINX_BEFORE="$(https_file_fingerprint "$TARGET_NGINX_CONF")" || fail "Unable to fingerprint target nginx configuration"
    TARGET_TLS_CERT_BEFORE="$(https_file_fingerprint "$TARGET_TLS_CERT")" || fail "Unable to fingerprint target TLS certificate"
    TARGET_TLS_KEY_BEFORE="$(https_file_fingerprint "$TARGET_TLS_KEY")" || fail "Unable to fingerprint target TLS key"
}

verify_target_https_identity() {
    [ "$(https_file_fingerprint "$TARGET_NGINX_CONF")" = "$TARGET_NGINX_BEFORE" ] || fail "Target nginx configuration changed"
    [ "$(https_file_fingerprint "$TARGET_TLS_CERT")" = "$TARGET_TLS_CERT_BEFORE" ] || fail "Target TLS certificate changed"
    [ "$(https_file_fingerprint "$TARGET_TLS_KEY")" = "$TARGET_TLS_KEY_BEFORE" ] || fail "Target TLS key changed"
}

restore_target_configuration_identity() {
    echo
    echo "=================================================="
    echo "CONFIGURATION / IDENTITY PHASE"
    echo "=================================================="
    echo "Restoring historical WAPT identity and policy while preserving target runtime settings."

    TARGET_INI="/opt/wapt/conf/waptserver.ini"
    SOURCE_INI="$BUNDLE/config/waptserver.ini"
    [ -f "$TARGET_INI" ] || fail "Target waptserver.ini is missing: $TARGET_INI"
    [ -f "$SOURCE_INI" ] || fail "Source waptserver.ini is missing from bundle"

    MERGED_INI="$(mktemp /opt/wapt/conf/.waptserver.ini.restore.XXXXXX)" || \
        fail "Unable to create temporary merged waptserver.ini"
    cp -a "$TARGET_INI" "$MERGED_INI" || fail "Unable to seed merged waptserver.ini"

    RESTORE_KEYS="allow_unauthenticated_connect allow_unauthenticated_registration clients_signing_certificate clients_signing_key secret_key server_uuid wapt_password"
    for key in $RESTORE_KEYS; do
        source_value="$(wapt_ini_value "$SOURCE_INI" "$key")"
        [ -n "$source_value" ] || fail "Source waptserver.ini value missing: $key"
        awk -v wanted="$key" -v value="$source_value" '
            BEGIN { replaced=0 }
            {
                line=$0
                split(line,a,"=")
                lhs=a[1]
                gsub(/^[ \t]+|[ \t]+$/, "", lhs)
                if (lhs == wanted) {
                    print wanted " = " value
                    replaced=1
                } else {
                    print line
                }
            }
            END { if (!replaced) exit 42 }
        ' "$MERGED_INI" > "${MERGED_INI}.new" || {
            rm -f -- "${MERGED_INI}.new" "$MERGED_INI"
            fail "Unable to merge WAPT identity/policy key: $key"
        }
        mv "${MERGED_INI}.new" "$MERGED_INI" || fail "Unable to update merged waptserver.ini"
    done

    # Runtime/technical keys remain authoritative from the target installation.
    RUNTIME_KEYS="chdir gid http-socket processes uid wapt_folder wapt_huey_db wapt_user waptwua_folder wsgi master enable-threads max-requests"
    for key in $RUNTIME_KEYS; do
        before="$(wapt_ini_value "$TARGET_INI" "$key")"
        after="$(wapt_ini_value "$MERGED_INI" "$key")"
        [ "$before" = "$after" ] || {
            rm -f -- "$MERGED_INI"
            fail "Target runtime setting changed unexpectedly during merge: $key"
        }
    done

    SOURCE_CA_KEY="$BUNDLE/certificates/client-ca/$(basename "$CA_KEY")"
    SOURCE_CA_CERT="$BUNDLE/certificates/client-ca/$(basename "$CA_CERT")"

    MERGED_CA_KEY="$(wapt_ini_value "$MERGED_INI" clients_signing_key)"
    MERGED_CA_CERT="$(wapt_ini_value "$MERGED_INI" clients_signing_certificate)"
    [ -n "$MERGED_CA_KEY" ] || fail "Merged clients_signing_key is empty"
    [ -n "$MERGED_CA_CERT" ] || fail "Merged clients_signing_certificate is empty"
    case "$MERGED_CA_KEY" in /opt/wapt/conf/*) ;; *) fail "Refusing client signing key path outside /opt/wapt/conf: $MERGED_CA_KEY" ;; esac
    case "$MERGED_CA_CERT" in /opt/wapt/conf/*) ;; *) fail "Refusing client signing certificate path outside /opt/wapt/conf: $MERGED_CA_CERT" ;; esac

    for destination in "$TARGET_INI" "$MERGED_CA_KEY" "$MERGED_CA_CERT"; do
        if [[ "$destination" -ef "$TARGET_NGINX_CONF" || "$destination" -ef "$TARGET_TLS_CERT" || "$destination" -ef "$TARGET_TLS_KEY" ]]; then
            fail "WAPT identity destination aliases a protected HTTPS file: $destination"
        fi
    done

    install -d -o wapt -g root -m 0750 /opt/wapt/conf || fail "Unable to secure /opt/wapt/conf"

    install -o wapt -g root -m 0640 "$SOURCE_CA_KEY" "$MERGED_CA_KEY" || fail "Unable to restore client signing key"
    install -o wapt -g root -m 0644 "$SOURCE_CA_CERT" "$MERGED_CA_CERT" || fail "Unable to restore client signing certificate"

    install -o wapt -g root -m 0640 "$MERGED_INI" "$TARGET_INI" || fail "Unable to install merged waptserver.ini"
    rm -f -- "$MERGED_INI"

    for key in $RESTORE_KEYS; do
        source_value="$(wapt_ini_value "$SOURCE_INI" "$key")"
        target_value="$(wapt_ini_value "$TARGET_INI" "$key")"
        [ "$source_value" = "$target_value" ] || fail "Restored WAPT identity/policy value mismatch: $key"
    done

    cmp -s "$SOURCE_CA_KEY" "$MERGED_CA_KEY" || fail "Restored client signing key content mismatch"
    cmp -s "$SOURCE_CA_CERT" "$MERGED_CA_CERT" || fail "Restored client signing certificate content mismatch"

    [ "$(stat -c '%a|%U|%G' "$TARGET_INI")" = "640|wapt|root" ] || fail "Unexpected waptserver.ini permissions"
    [ "$(stat -c '%a|%U|%G' "$MERGED_CA_KEY")" = "640|wapt|root" ] || fail "Unexpected client signing key permissions"
    [ "$(stat -c '%a|%U|%G' "$MERGED_CA_CERT")" = "644|wapt|root" ] || fail "Unexpected client signing certificate permissions"

    verify_target_https_identity
    ok "Target nginx configuration and TLS files preserved"

    systemctl is-active --quiet waptserver && fail "waptserver unexpectedly active after configuration/identity restore"
    systemctl is-active --quiet postgresql || fail "PostgreSQL unexpectedly inactive after configuration/identity restore"

    echo
    echo "Historical WAPT service FQDN: ${SOURCE_FQDN:-unknown}"
    echo "Current OS hostname:           $(hostname -f 2>/dev/null || hostname)"
    echo "Package prefix:                ${PACKAGE_PREFIX:-unknown} (informational; not changed by this phase)"
    echo "Target nginx configuration:    preserved"
    ok "WAPT configuration and identity restored and validated"
}


restore_repository_tool() {
    python3 - "$@" <<'PY'
import ctypes
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tarfile
from pathlib import Path

ARTIFACTS = ("waptsetup-tis.exe", "waptdeploy.exe", "Thouet-Software-Signing-Root-CA.cer")
REPOSITORY = "repository/wapt"
MARGIN = 2 * 1024**3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def member_path(name):
    if name.startswith("./"):
        name = name[2:]
    parts = name.split("/")
    require(all(part and part not in (".", "..") for part in parts), "Unsafe TAR or manifest path")
    return name


def inventory(archive):
    members = {}
    root = None
    for member in archive:
        name = member_path(member.name.rstrip("/") if member.isdir() else member.name)
        head, _, relative = name.partition("/")
        if root is None:
            root = head
        require(root == head and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", root),
                "Expected one named DR bundle root")
        require(relative not in members and (relative or member.isdir()), "Duplicate or invalid TAR member")
        require(member.isdir() or (member.type in (tarfile.REGTYPE, tarfile.AREGTYPE)
                                    and member.sparse is None),
                f"TAR links, sparse files and special files are forbidden: {name!r}")
        require(not relative.startswith("repository/") or relative == REPOSITORY
                or relative.startswith(REPOSITORY + "/"), "Unexpected repository path in bundle")
        members[relative] = member
    require(root is not None, "Empty DR archive")
    for name in members:
        parent = name.rpartition("/")[0]
        while parent:
            require(parent not in members or members[parent].isdir(), "TAR file used as directory")
            parent = parent.rpartition("/")[0]
    return root, members


def digest(path):
    with path.open("rb") as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
        return checksum.hexdigest()


def checksums(path):
    result = {}
    with path.open("rb") as stream:
        for line in stream:
            line = line.removesuffix(b"\n")
            escaped = line.startswith(b"\\")
            if escaped:
                line = line[1:]
            match = re.fullmatch(rb"([0-9a-fA-F]{64}) [ *](.+)", line)
            require(match is not None, "Invalid SHA256 manifest entry")
            checksum, name = match.groups()
            if escaped:
                require(not re.search(rb"\\(?![\\nr])", name), "Invalid SHA256 filename escape")
                name = re.sub(rb"\\([\\nr])", lambda m: {b"\\": b"\\", b"n": b"\n", b"r": b"\r"}[m[1]], name)
            name = member_path(os.fsdecode(name))
            require(name not in result, "Duplicate SHA256 manifest entry")
            result[name] = checksum.decode("ascii").lower()
    return result


def extract_member(archive, member, destination):
    if member.isdir():
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    else:
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with archive.extractfile(member) as source, destination.open("xb") as output:
            shutil.copyfileobj(source, output, 1024 * 1024)


def repository_member(name):
    return name == REPOSITORY or name.startswith(REPOSITORY + "/")


def verify_metadata(members, bundle):
    sums = checksums(bundle / "SHA256SUMS")
    files = {name for name, member in members.items() if member.isfile() and name != "SHA256SUMS"}
    require(files == sums.keys(), "SHA256SUMS does not cover every bundle file exactly once")
    for name, checksum in sums.items():
        if not repository_member(name):
            require(digest(bundle / name) == checksum, f"Bundle SHA256 mismatch: {name!r}")
    return sums


def directory_id(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode), f"Expected a directory without symlinks: {path}")
    return [info.st_dev, info.st_ino]


def layout(live, transaction, receipt):
    current = directory_id(live)
    other = directory_id(transaction / "repository")
    if current == receipt["original"] and other == receipt["prepared"]:
        return "prepared"
    if current == receipt["prepared"] and other == receipt["original"]:
        return "switched"
    raise ValueError("Repository state changed since preparation; retained directories require review")


def read_receipt(path, ready=False):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "Ambiguous repository receipt type")
    try:
        receipt = json.loads(path.read_text(encoding="ascii"))
    except (OSError, ValueError) as error:
        raise ValueError("Unreadable repository receipt; staging retained") from error
    fields = {"original", "prepared", "manifest", "artifacts"} if ready else {"original", "prepared"}
    require(isinstance(receipt, dict) and receipt.keys() == fields, "Ambiguous repository receipt fields")
    for key in ("original", "prepared"):
        pair = receipt[key]
        require(isinstance(pair, list) and len(pair) == 2 and
                all(type(value) is int and value >= 0 for value in pair), "Ambiguous repository identity")
    require(receipt["original"] != receipt["prepared"], "Repository receipt aliases the original")
    if ready:
        artifacts = receipt["artifacts"]
        require(isinstance(artifacts, dict) and artifacts.keys() == set(ARTIFACTS) and
                all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                    for value in [receipt["manifest"], *artifacts.values()]), "Ambiguous repository receipt hashes")
    return receipt


def repository_state(live, transaction):
    names = {entry.name for entry in transaction.iterdir()}
    if not names:
        return "empty", None
    require("repository" in names and names <= {"repository", "building.json", "ready.json", "ready.pending"},
            "Ambiguous repository transaction; staging retained")
    building = read_receipt(transaction / "building.json") if "building.json" in names else None
    if "ready.json" in names:
        require("ready.pending" not in names, "Ambiguous pending ready receipt; staging retained")
        receipt = read_receipt(transaction / "ready.json", ready=True)
        require(building is None or all(receipt[key] == value for key, value in building.items()),
                "Inconsistent repository receipts; staging retained")
        return layout(live, transaction, receipt), receipt
    require(building is not None and layout(live, transaction, building) == "prepared",
            "Cannot prove staging is an incomplete preparation; staging retained")
    if "ready.pending" in names:
        pending = (transaction / "ready.pending").lstat()
        require(stat.S_ISREG(pending.st_mode) and pending.st_nlink == 1,
                "Unsafe pending receipt; staging retained")
    return "building", building


def validate_no_mounts(staged):
    root = os.fsencode(staged)
    with open("/proc/self/mountinfo", "rb") as mounts:
        for line in mounts:
            name = line.split()[4]
            name = re.sub(rb"\\([0-7]{3})", lambda match: bytes([int(match[1], 8)]), name)
            require(name != root and not name.startswith(root + b"/"),
                    "Mount inside repository staging; staging retained")


def allocated_bytes(info):
    return info.st_blocks * 512


def reclaimable_bytes(staged):
    validate_no_mounts(staged)
    device = staged.lstat().st_dev
    total = 0

    def walk_error(error):
        raise error

    for parent, dirs, files in os.walk(staged, onerror=walk_error):
        for name in dirs + files:
            path = Path(parent) / name
            info = path.lstat()
            safe_type = stat.S_ISDIR(info.st_mode) if name in dirs else (
                stat.S_ISREG(info.st_mode) and info.st_nlink == 1
            )
            require(info.st_dev == device and safe_type, "Unsafe entry in incomplete staging; staging retained")
            total += allocated_bytes(info)
    return total


def write_receipt(transaction, name, receipt):
    pending = transaction / (name + ".pending")
    with pending.open("x", encoding="ascii") as stream:
        json.dump(receipt, stream)
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(transaction / (name + ".json"))
    sync_directory(transaction)


def package_hashes(repo):
    result = {}
    for name in ARTIFACTS:
        path = repo / name
        require(stat.S_ISREG(path.lstat().st_mode), f"PADIT artifact is not a regular file: {name}")
        result[name] = digest(path)
    return result


def verify_repository(repo, expected):
    actual = set()
    for parent, dirs, files in os.walk(repo, onerror=lambda err: require(False, str(err))):
        for name in dirs:
            directory_id(Path(parent) / name)
        for name in files:
            path = Path(parent) / name
            relative = path.relative_to(repo).as_posix()
            require(stat.S_ISREG(path.lstat().st_mode), f"Unexpected repository entry: {relative!r}")
            require(relative in expected and digest(path) == expected[relative],
                    f"Repository SHA256 mismatch or unexpected file: {relative!r}")
            actual.add(relative)
    require(actual == expected.keys(), "Repository files are missing")


def exchange(first, second):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    if rename(-100, os.fsencode(first), -100, os.fsencode(second), 2) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def estimate(entries):
    volumes = {}
    for path, amount in entries:
        device = os.stat(path).st_dev
        data = os.statvfs(path)
        free = data.f_bavail * data.f_frsize
        entry = volumes.setdefault(device, [MARGIN, free, []])
        entry[0] += int(amount)
        entry[1] = min(entry[1], free)
        entry[2].append(str(path))
    for required, free, paths in volumes.values():
        label = ", ".join(paths)
        print(f"Restore disk estimate for {label}: {required} bytes needed, {free} available", file=sys.stderr)
        require(free >= required, f"Insufficient estimated disk space on volume for {label}")


def prepare(archive, members, bundle, live, transaction, checks, manifest_count, uid, gid):
    staged = transaction / "repository"
    sums = verify_metadata(members, bundle)
    source = checksums(checks)
    prefix = REPOSITORY + "/"
    require(source == {name[len(prefix):]: checksum for name, checksum in sums.items()
                       if name.startswith(prefix)}, "Repository manifest and bundle SHA256SUMS disagree")
    require(len(source) == int(manifest_count) and "Packages" in source
            and all(name in source for name in ARTIFACTS[:2]), "Unexpected repository manifest contents")
    manifest_id = digest(bundle / "SHA256SUMS")
    state, receipt = repository_state(live, transaction)
    if state in ("prepared", "switched"):
        require(receipt["manifest"] == manifest_id, "Prepared repository belongs to a different bundle")
        original, candidate = (live, staged) if state == "prepared" else (staged, live)
        require(package_hashes(original) == receipt["artifacts"], "Original PADIT artifacts changed")
        verify_repository(candidate, {**source, **receipt["artifacts"]})
        return state

    if state == "empty":
        staged.mkdir(mode=0o700)
        building = {"original": directory_id(live), "prepared": directory_id(staged)}
        write_receipt(transaction, "building", building)
    else:
        require(not any(staged.iterdir()) and not (transaction / "ready.pending").exists(),
                "Identified preparation must be cleared before extraction")
        building = receipt
    preserved = package_hashes(live)
    for name, member in members.items():
        if name.startswith(prefix):
            extract_member(archive, member, staged / name[len(prefix):])
    verify_repository(staged, source)
    for name in ARTIFACTS:
        shutil.copyfile(live / name, staged / name)
        require(digest(staged / name) == preserved[name], f"PADIT artifact changed during staging: {name}")
    for parent, _, files in os.walk(staged, onerror=lambda err: require(False, str(err))):
        os.chown(parent, uid, gid)
        os.chmod(parent, 0o750)
        for name in files:
            path = Path(parent) / name
            os.chown(path, uid, gid)
            os.chmod(path, 0o640)
    require(layout(live, transaction, building) == "prepared", "Repository changed during preparation")
    receipt = {**building, "manifest": manifest_id, "artifacts": preserved}
    os.sync()
    write_receipt(transaction, "ready", receipt)
    return "prepared"


def main(args):
    action, *args = args
    if action == "probe":
        from tempfile import TemporaryDirectory
        with TemporaryDirectory(dir=args[0]) as path:
            first, second = Path(path) / "a", Path(path) / "b"
            first.mkdir()
            second.mkdir()
            exchange(first, second)
        return
    if action == "space":
        estimate(zip(args[::2], args[1::2]))
        return
    if action in ("reservation", "clear-incomplete"):
        live, transaction = map(Path, args[:2])
        state, receipt = repository_state(live, transaction)
        staged = transaction / "repository"
        reclaim = reclaimable_bytes(staged) if state == "building" else 0
        if action == "reservation":
            # Credit blocks already occupied by files that a controlled reset can reclaim.
            print(0 if state in ("prepared", "switched") else int(args[2]) - reclaim)
        elif state == "building":
            require(layout(live, transaction, receipt) == "prepared", "Repository changed before reset")
            for entry in staged.iterdir():
                if entry.is_dir():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()
            (transaction / "ready.pending").unlink(missing_ok=True)
            sync_directory(staged)
            sync_directory(transaction)
            print("cleared")
        return
    if action == "switch":
        live, transaction = map(Path, args)
        state, receipt = repository_state(live, transaction)
        require(state in ("prepared", "switched"), "Repository is not ready for activation")
        staged = transaction / "repository"
        if state == "prepared":
            require(package_hashes(live) == receipt["artifacts"], "Live PADIT artifacts changed before switch")
            exchange(live, staged)
        require(layout(live, transaction, receipt) == "switched", "Repository exchange did not complete")
        sync_directory(live.parent)
        sync_directory(transaction)
        print(f"Previous repository retained at {staged}")
        return
    filename, *args = args
    with tarfile.open(filename, "r:") as archive:
        root, members = inventory(archive)
        if action == "scan":
            work = sum(member.size + 4096 for name, member in members.items() if not repository_member(name))
            repo = sum(member.size + 4096 for name, member in members.items() if repository_member(name))
            print(root, work, repo)
        elif action == "metadata":
            bundle = Path(args[0])
            bundle.mkdir(mode=0o700)
            for name, member in members.items():
                if name and not repository_member(name):
                    extract_member(archive, member, bundle / name)
            verify_metadata(members, bundle)
        elif action == "prepare":
            bundle, live, transaction, checks = map(Path, args[:4])
            print(prepare(archive, members, bundle, live, transaction, checks,
                          args[4], int(args[5]), int(args[6])))
        else:
            raise ValueError(f"Unknown DR repository action: {action}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError, AttributeError, KeyError, tarfile.TarError) as error:
        sys.exit(f"[FAIL] DR {sys.argv[1]}: {error}")
PY
}

open_restore_repository() {
    TARGET_REPO="/var/www/wapt"
    REPO_STATE_ROOT="/var/www/.wapt-dr-repository"
    (
        WORK_PARENT=/var/www
        validate_work_parent
    ) || fail "Unsafe target repository parent"
    local owner_mode
    owner_mode="$(stat -c '%u:%a' -- /var/www)" || fail "Unable to inspect target repository parent"
    [[ "$owner_mode" =~ ^0:([0-7]{3,4})$ ]] &&
        (( (8#${BASH_REMATCH[1]} & 0022) == 0 )) ||
        fail "Target repository parent must be root-owned and protected from group/other writes"
    [ -d "$TARGET_REPO" ] && [ ! -L "$TARGET_REPO" ] || fail "Unsafe or missing target repository"
    local mount_status=0
    mountpoint -q -- "$TARGET_REPO" || mount_status=$?
    [ "$mount_status" -eq 32 ] || fail "Target repository must be a directory on its parent's volume, not a mount point"

    if [ ! -e "$REPO_STATE_ROOT" ]; then
        mkdir -m 0700 -- "$REPO_STATE_ROOT" || fail "Unable to create repository recovery directory"
    fi
    [ ! -L "$REPO_STATE_ROOT" ] && [ -d "$REPO_STATE_ROOT" ] &&
        [ "$(stat -c '%u:%a:%d' -- "$REPO_STATE_ROOT")" = "0:700:$(stat -c %d -- "$TARGET_REPO")" ] ||
        fail "Unsafe repository recovery directory or repository volume mismatch"
    exec {REPO_LOCK_FD}< "$REPO_STATE_ROOT" || fail "Unable to open repository recovery directory"
    flock -n "$REPO_LOCK_FD" || fail "Another repository restore is in progress"
    restore_repository_tool probe "$REPO_STATE_ROOT" || fail "Repository volume does not support atomic directory exchange"

    REPO_TRANSACTION="$REPO_STATE_ROOT/$RESTORE_ARCHIVE_SHA"
    if [ ! -e "$REPO_TRANSACTION" ]; then
        mkdir -m 0700 -- "$REPO_TRANSACTION" || fail "Unable to create repository preparation directory"
    fi
    [ ! -L "$REPO_TRANSACTION" ] && [ -d "$REPO_TRANSACTION" ] &&
        [ "$(stat -c '%u:%a:%d' -- "$REPO_TRANSACTION")" = "0:700:$(stat -c %d -- "$TARGET_REPO")" ] ||
        fail "Unsafe repository preparation directory"
    if [ -e /var/www/padit-backups ] || [ -L /var/www/padit-backups ]; then
        [ ! -L /var/www/padit-backups ] && [ -d /var/www/padit-backups ] &&
            [ "$(stat -c '%u:%a' -- /var/www/padit-backups)" = "0:700" ] ||
            fail "Unsafe target safety backup directory"
    fi
}

prepare_restore_repository() {
    local pg_disk pg_data pg_bytes dump_bytes artifact_bytes config_bytes safety_volume repo_bytes reset uid gid
    local -a space_budget
    pg_disk="$(cd / && runuser -u postgres -- psql -p "$TARGET_PG_PORT" -d wapt -Atq -F '|' \
        -c "SELECT current_setting('data_directory'), pg_database_size(current_database());")" ||
        fail "Unable to estimate PostgreSQL disk space"
    IFS='|' read -r pg_data pg_bytes <<< "$pg_disk"
    [[ "$pg_data" = /* && "$pg_bytes" =~ ^[0-9]+$ ]] || fail "Invalid PostgreSQL space estimate"
    dump_bytes="$(stat -Lc %s -- "$BUNDLE/database/wapt.dump")" || fail "Unable to size PostgreSQL dump"
    artifact_bytes="$(stat -Lc %s -- "$TARGET_REPO/"{waptsetup-tis.exe,waptdeploy.exe,Thouet-Software-Signing-Root-CA.cer} |
        awk '{sum += $1} END {printf "%.0f\n", sum}')"
    config_bytes="$(du -sb -- /opt/wapt/conf /opt/wapt/waptserver/ssl /etc/nginx/sites-available/wapt.conf 2>/dev/null |
        awk '{sum += $1} END {printf "%.0f\n", sum}')"
    safety_volume=/var/www
    [ ! -d /var/www/padit-backups ] || safety_volume=/var/www/padit-backups
    repo_bytes="$(restore_repository_tool reservation "$TARGET_REPO" "$REPO_TRANSACTION" "$((RESTORE_REPO_BYTES + artifact_bytes))")" ||
        fail "Unable to estimate repository staging space"
    space_budget=(
        "$safety_volume" "$((2 * (pg_bytes + config_bytes + artifact_bytes)))"
        "$pg_data" "$((2 * (pg_bytes > dump_bytes ? pg_bytes : dump_bytes)))"
    )
    restore_repository_tool space "$TARGET_REPO" "$repo_bytes" "${space_budget[@]}" ||
        fail "Restore disk estimate failed before PostgreSQL changes"
    reset="$(restore_repository_tool clear-incomplete "$TARGET_REPO" "$REPO_TRANSACTION")" ||
        fail "Unable to reset the proven incomplete preparation before PostgreSQL changes"
    if [ "$reset" = "cleared" ]; then
        ok "Identified incomplete repository preparation cleared"
        restore_repository_tool space "$TARGET_REPO" "$((RESTORE_REPO_BYTES + artifact_bytes))" "${space_budget[@]}" ||
            fail "Actual free space after staging reset is insufficient before PostgreSQL changes"
    fi
    warn "Disk estimate groups shared volumes and uses current free space; PostgreSQL expansion, WAL and external tablespaces can require more space"
    uid="$(id -u wapt)" || fail "Unable to determine wapt user ID"
    gid="$(getent group www-data | cut -d: -f3)"
    [[ "$gid" =~ ^[0-9]+$ ]] || fail "Unable to determine www-data group ID"
    REPO_STAGE_STATE="$(restore_repository_tool prepare "$RESTORE_ARCHIVE" "$BUNDLE" "$TARGET_REPO" \
        "$REPO_TRANSACTION" "$REPO_MANIFEST" "$REPO_FILES" "$uid" "$gid")" ||
        fail "Repository preparation failed before PostgreSQL changes"
    ok "Repository and PADIT artifacts validated ($REPO_STAGE_STATE)"
}

restore_target_repository() {
    systemctl is-active --quiet waptserver && fail "waptserver must be stopped before repository activation"
    systemctl is-active --quiet postgresql || fail "PostgreSQL unexpectedly inactive before repository activation"
    restore_repository_tool switch "$TARGET_REPO" "$REPO_TRANSACTION" || fail "Unable to activate prepared repository"
    ok "Validated repository active; previous repository retained"
}

validate_and_start_services() {
    echo
    echo "=================================================="
    echo "SERVICE / FQDN / TLS VALIDATION PHASE"
    echo "=================================================="

    verify_target_https_identity

    TLS_PUB_CERT="$(openssl x509 -in "$TARGET_TLS_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform pem 2>/dev/null)" || \
        fail "Unable to read public key from target TLS certificate"
    TLS_PUB_KEY="$(openssl pkey -in "$TARGET_TLS_KEY" -pubout -outform pem 2>/dev/null)" || \
        fail "Unable to read public key from target TLS private key"
    [ "$TLS_PUB_CERT" = "$TLS_PUB_KEY" ] || fail "Target TLS certificate/private key do not match"
    ok "Target TLS certificate/private key match"

    WAPT_SERVICE_FQDN="$(openssl x509 -in "$TARGET_TLS_CERT" -noout -subject -nameopt RFC2253 2>/dev/null | \
        sed -n -E 's/^subject=.*CN=([^,]+).*$/\1/p' | head -n 1)"
    [ -n "$WAPT_SERVICE_FQDN" ] || fail "Unable to derive target WAPT service FQDN from target TLS certificate CN"
    case "$WAPT_SERVICE_FQDN" in
        *.*) ;;
        *) fail "Target TLS certificate CN does not look like a FQDN: $WAPT_SERVICE_FQDN" ;;
    esac
    case "$WAPT_SERVICE_FQDN" in
        *[!A-Za-z0-9.-]*) fail "Target TLS certificate CN contains unsupported FQDN characters: $WAPT_SERVICE_FQDN" ;;
    esac

    TLS_NOT_AFTER="$(openssl x509 -in "$TARGET_TLS_CERT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" || \
        fail "Unable to read target TLS certificate expiry"
    openssl x509 -in "$TARGET_TLS_CERT" -noout -checkend 0 >/dev/null 2>&1 || \
        fail "Target TLS certificate is already expired"
    ok "Target TLS certificate is currently valid"

    TARGET_OS_FQDN="$(hostname -f 2>/dev/null || hostname)"
    echo
    echo "Source OS FQDN:       ${SOURCE_FQDN:-unknown}"
    echo "WAPT service FQDN:    $WAPT_SERVICE_FQDN"
    echo "Target OS FQDN:       $TARGET_OS_FQDN"
    echo "TLS certificate ends: $TLS_NOT_AFTER"

    DNS_RESULT=""
    if command -v getent >/dev/null 2>&1; then
        DNS_RESULT="$(getent ahostsv4 "$WAPT_SERVICE_FQDN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    fi
    if [ -n "$DNS_RESULT" ]; then
        echo "Current DNS IPv4:     $DNS_RESULT"
        warn "DNS result is informational only; this restore does not change DNS or authorize production-client reconnection"
    else
        echo "Current DNS IPv4:     <not resolved from this target>"
        warn "Target WAPT service FQDN does not currently resolve here; this is acceptable for an isolated DR validation"
    fi

    command -v nginx >/dev/null 2>&1 || fail "nginx command is unavailable"
    nginx -t >/dev/null 2>&1 || fail "Target nginx configuration test failed"
    ok "nginx configuration test passed"

    systemctl is-active --quiet postgresql || fail "PostgreSQL is not active before WAPT service start"
    systemctl is-active --quiet nginx || fail "nginx is not active before WAPT service start"

    echo
    echo "Starting/validating WAPT application services..."
    if systemctl is-active --quiet waptserver; then
        warn "waptserver is already active; accepting service-resume state"
    else
        systemctl start waptserver || fail "Unable to start waptserver"
    fi

    WAPTSERVER_READY="no"
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet waptserver; then
            WAPTSERVER_READY="yes"
            break
        fi
        sleep 1
    done
    [ "$WAPTSERVER_READY" = "yes" ] || fail "waptserver did not become active within 10 seconds"
    ok "waptserver is active"

    if systemctl list-unit-files wapttasks.service 2>/dev/null | grep -q '^wapttasks\.service'; then
        if systemctl is-active --quiet wapttasks; then
            warn "wapttasks is already active; accepting service-resume state"
        else
            systemctl start wapttasks || fail "Unable to start wapttasks"
        fi

        WAPTTASKS_READY="no"
        for _attempt in 1 2 3 4 5; do
            if systemctl is-active --quiet wapttasks; then
                WAPTTASKS_READY="yes"
                break
            fi
            sleep 1
        done
        [ "$WAPTTASKS_READY" = "yes" ] || fail "wapttasks did not become active within 5 seconds"
        ok "wapttasks is active"
    else
        warn "wapttasks.service is not installed; no wapttasks start attempted"
    fi

    command -v curl >/dev/null 2>&1 || fail "curl command is unavailable for local HTTPS validation"
    echo
    echo "Waiting for local WAPT HTTPS readiness (maximum 30 seconds)..."
    LOCAL_HTTPS_CODE=""
    HTTPS_READY="no"
    for _attempt in $(seq 1 30); do
        LOCAL_HTTPS_CODE="$(curl -k -sS -o /dev/null -w '%{http_code}' \
            --resolve "${WAPT_SERVICE_FQDN}:443:127.0.0.1" \
            "https://${WAPT_SERVICE_FQDN}/" 2>/dev/null || true)"
        case "$LOCAL_HTTPS_CODE" in
            2??|3??|401|403)
                HTTPS_READY="yes"
                break
                ;;
        esac
        sleep 1
    done
    [ "$HTTPS_READY" = "yes" ] || \
        fail "Local WAPT HTTPS endpoint did not become ready within 30 seconds (last status: ${LOCAL_HTTPS_CODE:-none})"
    verify_target_https_identity
    ok "Local HTTPS validation passed with HTTP status $LOCAL_HTTPS_CODE"

    echo
    echo "SERVICE / FQDN / TLS VALIDATION PASSED"
    echo "The restored WAPT service is running locally with the preserved target TLS identity."
    echo
    echo "=================================================="
    echo "PRE-PRODUCTION CUTOVER BARRIER"
    echo "=================================================="
    echo "Target WAPT service FQDN:     $WAPT_SERVICE_FQDN"
    echo "Current target OS FQDN:       $TARGET_OS_FQDN"
    echo "Current DNS IPv4:             ${DNS_RESULT:-<not resolved>}"
    echo
    echo "DO NOT reconnect production clients yet."
    echo "DO NOT change production DNS as part of this script."
    echo "Before production cutover, explicitly validate that:"
    echo "  1. $WAPT_SERVICE_FQDN resolves to the intended restored production server;"
    echo "  2. network/firewall/ACL rules permit the intended client traffic;"
    echo "  3. the TLS identity presented for $WAPT_SERVICE_FQDN is the intended target certificate;"
    echo "  4. the WAPT console is used to regenerate waptagent.exe with the intended authorized certificate(s)."
    echo
    warn "TLS certificate renewal must be planned before: $TLS_NOT_AFTER"
}

fetch_backup() (
    local host="${1:-}" user="${2:-}" remote_path="${3:-}"
    local backup_root="/var/www/padit-transfer"
    local archive remote destination owner permissions expected actual tool

    if [ -z "$host" ]; then
        [ -t 0 ] && IFS= read -r -p "Source SSH host: " host || fail "Missing source SSH host"
    fi
    if [ -z "$user" ]; then
        [ -t 0 ] && IFS= read -r -p "SSH user: " user || fail "Missing SSH user"
    fi
    if [ -z "$remote_path" ]; then
        [ -t 0 ] && IFS= read -r -p "Absolute remote .tar path: " remote_path || fail "Missing remote archive path"
    fi

    # Bracket IPv6 for SCP's user@host:path syntax.
    if [[ "$host" == *:* ]]; then
        [[ "$host" =~ ^[0-9a-fA-F:.]+(%[a-zA-Z0-9_.-]+)?$ ]] || fail "Invalid SSH host"
        host="[$host]"
    else
        [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9.])?$ ]] || fail "Invalid SSH host"
    fi
    [[ "$user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || fail "Invalid SSH user"
    [[ "$remote_path" =~ ^(/[a-zA-Z0-9_.-]+)+\.tar$ ]] || fail "Unsafe remote archive path"
    case "$remote_path/" in
        */../*|*/./*) fail "Unsafe remote archive path" ;;
    esac
    archive="${remote_path##*/}"
    [[ "$archive" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*\.tar$ ]] || fail "Unsafe archive name"
    remote="${user}@${host}:${remote_path}"
    destination="fetch-${archive%.tar}"

    for tool in scp sha256sum awk realpath stat id mkdir chmod rm rmdir; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required tool missing: $tool"
    done

    umask 077
    [ "$(realpath -m -- "$backup_root")" = "$backup_root" ] || fail "Unsafe backup root: $backup_root"
    if [ ! -d "$backup_root" ]; then
        mkdir -m 0700 -- "$backup_root" || fail "Cannot create backup root: $backup_root"
    fi
    cd -P -- "$backup_root" || fail "Cannot enter backup root: $backup_root"
    [ "$PWD" = "$backup_root" ] || fail "Unsafe backup root: $backup_root"
    owner="$(stat -c %u -- .)" || fail "Cannot inspect backup root owner"
    permissions="$(stat -c %a -- .)" || fail "Cannot inspect backup root permissions"
    [ "$owner" = "$(id -u)" ] && (( (8#$permissions & 0022) == 0 )) || \
        fail "Backup root must be owned by the invoking user and protected from group/other writes"

    # Reserve the destination atomically. Keep transfers tied to the reserved directory.
    mkdir -m 0700 -- "$destination" || fail "Cannot reserve staging destination (already exists or cannot be created): $backup_root/$destination"
    cd -P -- "$destination" || fail "Cannot enter reserved staging directory"
    trap '
        rm -f -- "./$archive" "./$archive.sha256"
        if [[ "../$destination" -ef . ]]; then
            rmdir -- "../$destination"
        fi
    ' EXIT
    trap 'fail "Remote fetch interrupted"' HUP INT TERM

    local -a scp_options=(-o StrictHostKeyChecking=yes -o NoHostAuthenticationForLocalhost=no -o ControlPath=none -o ConnectTimeout=15)
    scp "${scp_options[@]}" -- "$remote.sha256" "./$archive.sha256" || \
        fail "SHA256 sidecar transfer failed (missing or unreadable sidecar, SSH error, or local write failure)"
    expected="$(awk 'NF {print $1; exit}' "./$archive.sha256")" || fail "Cannot read SHA256 sidecar"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || fail "Invalid SHA256 sidecar"

    scp "${scp_options[@]}" -- "$remote" "./$archive" || \
        fail "Archive transfer failed (SSH error, incomplete transfer, or local write failure such as insufficient space)"
    [ -s "./$archive" ] || fail "Transferred archive is missing or empty"
    actual="$(sha256sum -- "./$archive")" || fail "Cannot calculate transferred archive SHA256"
    actual="${actual%% *}"
    [ "${actual,,}" = "${expected,,}" ] || fail "Transferred archive SHA256 mismatch"
    chmod 0600 -- "./$archive" "./$archive.sha256" || fail "Cannot secure transferred files"

    [[ "$backup_root/$destination" -ef . ]] || fail "Staging destination changed during transfer"
    trap - EXIT HUP INT TERM
    ok "Remote archive SHA256 verified"
    printf 'Archive retained: %s/%s/%s\n' "$backup_root" "$destination" "$archive"
    printf 'To validate the backup: %q --check %q\n' "$0" "$backup_root/$destination/$archive"
)

usage() {
    echo "Usage: $0 {--check|--restore} [--work-dir /absolute/path] /path/to/wapt-dr-*.tar"
    echo "       $0 {--check|--restore} /path/to/wapt-dr-*.tar [--work-dir /absolute/path]"
    echo "The work directory defaults to /var/www and is prompted for on a terminal when omitted."
    echo "If /var/www is unsafe, select an existing directory such as /var/tmp."
    echo "       $0 --fetch [HOST [SSH_USER [/absolute/path/to/archive.tar]]]"
    echo "       $0 --fetch scrab backupuser /var/www/wapt-backups/wapt-dr-example.tar"
    echo "Missing fetch arguments are prompted for on a terminal. SSH handles authentication."
    echo "The host key must already be trusted by the invoking account, which must own the backup root."
    echo "Fetch retains a verified archive for a separate --check."
    exit 2
}

if [ "${1:-}" = "--fetch" ]; then
    shift
    [ "$#" -le 3 ] || usage
    fetch_backup "$@"
    exit $?
fi

MODE="${1:-}"

case "$MODE" in
    --check|--restore) ;;
    *) usage ;;
esac

WORK_PARENT="/var/www"
case "$#" in
    2)
        [ "$2" != "--work-dir" ] || usage
        ARCHIVE="$2"
        ;;
    4)
        if [ "$2" = "--work-dir" ]; then
            WORK_PARENT="$3"
            ARCHIVE="$4"
        elif [ "$3" = "--work-dir" ]; then
            ARCHIVE="$2"
            WORK_PARENT="$4"
        else
            usage
        fi
        ;;
    *) usage ;;
esac

if [ "$MODE" = "--restore" ] && [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "Root privileges are required for --restore and sudo is not available"
    exec sudo -- "$0" "$@"
fi

echo "WAPT Server DR restore v${SCRIPT_VERSION}"
echo "=================================================="
if [ "$MODE" = "--check" ]; then
    echo "Mode: CHECK ONLY — no target WAPT data will be modified"
else
    echo "Mode: RESTORE — validation phase only"
fi
echo

for tool in tar sha256sum awk grep sed find wc mktemp mkfifo pg_restore df stat sort install cmp hostname head openssl curl; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool missing: $tool"
    ok "Tool available: $tool"
done

[ -f "$ARCHIVE" ] || fail "Archive not found: $ARCHIVE"
ok "Archive found: $ARCHIVE"
[ -s "$ARCHIVE" ] || fail "Archive is empty"
ok "Archive is not empty"

if [ "$MODE" = "--restore" ]; then
    for tool in python3 flock mountpoint getent cut du; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required restore tool missing: $tool"
    done
    exec {RESTORE_ARCHIVE_FD}< "$ARCHIVE" || fail "Unable to open restore archive"
    RESTORE_ARCHIVE="/proc/$$/fd/$RESTORE_ARCHIVE_FD"
    RESTORE_ARCHIVE_SHA="$(sha256sum < "$RESTORE_ARCHIVE")" || fail "Unable to fingerprint restore archive"
    RESTORE_ARCHIVE_SHA="${RESTORE_ARCHIVE_SHA%% *}"
    [[ "$RESTORE_ARCHIVE_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid restore archive fingerprint"
fi
SIDECAR="${ARCHIVE}.sha256"
if [ -f "$SIDECAR" ]; then
    EXPECTED_ARCHIVE_SHA="$(awk 'NF {print $1; exit}' "$SIDECAR")"
    case "$EXPECTED_ARCHIVE_SHA" in
        ''|*[!0-9a-fA-F]*) fail "Invalid archive SHA256 sidecar: $SIDECAR" ;;
    esac
    [ "${#EXPECTED_ARCHIVE_SHA}" -eq 64 ] || fail "Invalid SHA256 length in sidecar"
    if [ "$MODE" = "--restore" ]; then
        ACTUAL_ARCHIVE_SHA="$RESTORE_ARCHIVE_SHA"
    else
        ACTUAL_ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    fi
    [ "${ACTUAL_ARCHIVE_SHA,,}" = "${EXPECTED_ARCHIVE_SHA,,}" ] || fail "Archive SHA256 sidecar mismatch"
    ok "Archive SHA256 sidecar validated"
else
    warn "Archive SHA256 sidecar not found: $SIDECAR"
fi

if [ "$MODE" = "--restore" ]; then
    RESTORE_INVENTORY="$(restore_repository_tool scan "$RESTORE_ARCHIVE")" || fail "Invalid restore archive"
    read -r BUNDLE_ROOT RESTORE_WORK_BYTES RESTORE_REPO_BYTES <<< "$RESTORE_INVENTORY"
    ok "Single bundle root found: $BUNDLE_ROOT"
else
tar -tf "$ARCHIVE" >/dev/null || fail "Tar archive is not readable"
ok "Tar archive is readable"

if tar -tf "$ARCHIVE" | awk '
    /^\// { bad=1 }
    {
        n=split($0,a,"/")
        for (i=1;i<=n;i++) if (a[i]=="..") bad=1
    }
    END { exit bad ? 0 : 1 }
'; then
    fail "Archive contains unsafe paths"
fi
ok "Archive paths are safe"

BUNDLE_ROOT="$(tar -tf "$ARCHIVE" | sed 's#^\./##' | awk -F/ 'NF && $1!="" {print $1}' | sort -u)"
ROOT_COUNT="$(printf '%s\n' "$BUNDLE_ROOT" | awk 'NF {n++} END {print n+0}')"
[ "$ROOT_COUNT" -eq 1 ] || fail "Archive must contain exactly one top-level bundle root"
ok "Single bundle root found: $BUNDLE_ROOT"
fi

validate_work_parent() {
    local remaining component path="" owner mode
    case "$WORK_PARENT" in
        /*) ;;
        *) fail "Work directory must be an absolute path: $WORK_PARENT" ;;
    esac
    remaining="${WORK_PARENT#/}"

    # Check each directory before traversing it. A trusted sticky directory
    # (such as /tmp) also protects trusted children from being renamed.
    while :; do
        path="${path:-/}"
        [ ! -L "$path" ] || fail "Work directory path contains a symbolic link: $path"
        [ -d "$path" ] || fail "Work directory path is not a directory: $path"
        [ -x "$path" ] || fail "Work directory path is not searchable: $path"
        read -r owner mode <<< "$(stat -c '%u %a' -- "$path")"
        [[ "$owner" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] || \
            fail "Unable to inspect work directory permissions: $path"
        if (( owner != 0 && owner != EUID )); then
            fail "Unsafe work directory component $path (owner UID $owner): its owner can rename entries. Retry with --work-dir /var/tmp or another existing trusted directory."
        fi
        if (( (8#$mode & 0022) && !(8#$mode & 01000) )); then
            fail "Work directory path has unsafe ownership or permissions: $path"
        fi
        if [ "$MODE" = "--restore" ] && [[ "$path" -ef /var/www/wapt ]]; then
            fail "Work directory must be outside the target WAPT repository: $path"
        fi

        [ -n "$remaining" ] || break
        component="${remaining%%/*}"
        if [[ "$remaining" = */* ]]; then
            remaining="${remaining#*/}"
        else
            remaining=""
        fi
        case "$component" in
            '') ;;
            .|..) fail "Work directory path cannot contain . or .. components: $WORK_PARENT" ;;
            *) path="${path%/}/$component" ;;
        esac
    done
    [ -w "$path" ] || fail "Work directory is not writable: $path"
    WORK_PARENT="$path"
}
work_free_bytes() {
    local report available
    report="$(LC_ALL=C df -PB1 -- "$1")" || return 1
    available="$(awk 'END {print $4}' <<< "$report")"
    [[ "$available" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$available"
}

ARCHIVE_BYTES="$(stat -Lc '%s' -- "$ARCHIVE")" || fail "Unable to determine archive size"
SAFETY_BYTES=$((2 * 1024 * 1024 * 1024))
BUDGET_LABEL="archive size + 2 GiB, extraction only"
REQUIRED_BYTES=$((ARCHIVE_BYTES + SAFETY_BYTES))
if [ "$MODE" = "--restore" ]; then
    BUDGET_LABEL="metadata and PostgreSQL dump + 2 GiB, work volume only"
    REQUIRED_BYTES=$((RESTORE_WORK_BYTES + SAFETY_BYTES))
fi

if [ "$#" -eq 2 ] && [ -t 0 ]; then
    echo >&2
    printf 'Archive size: %s bytes\n' "$ARCHIVE_BYTES" >&2
    printf 'Extraction budget: %s bytes (%s)\n' "$REQUIRED_BYTES" "$BUDGET_LABEL" >&2
    if PROPOSED_FREE="$(work_free_bytes "$WORK_PARENT" 2>/dev/null)"; then
        printf 'Available on proposed volume (%s): %s bytes\n' "$WORK_PARENT" "$PROPOSED_FREE" >&2
        if [ "$PROPOSED_FREE" -lt "$REQUIRED_BYTES" ]; then
            warn "Space: insufficient for the extraction budget on $WORK_PARENT"
        fi
    else
        warn "Space: unable to measure the proposed volume for $WORK_PARENT"
    fi
    if ! PARENT_ERROR="$(validate_work_parent 2>&1)"; then
        warn "Security/permissions: $PARENT_ERROR"
    fi
    printf 'Temporary work directory [%s] (Enter to accept, or enter another absolute path): ' "$WORK_PARENT" >&2
    IFS= read -r selected_parent || fail "Unable to read work directory choice"
    WORK_PARENT="${selected_parent:-$WORK_PARENT}"
fi

validate_work_parent
FREE_BYTES="$(work_free_bytes "$WORK_PARENT")" || fail "Unable to measure free space on $WORK_PARENT"

echo
echo "Restore check work filesystem: $WORK_PARENT"
echo "Archive size: $ARCHIVE_BYTES bytes"
echo "Free space:   $FREE_BYTES bytes"
echo "Required:     $REQUIRED_BYTES bytes ($BUDGET_LABEL)"

[ "$FREE_BYTES" -ge "$REQUIRED_BYTES" ] || \
    fail "Insufficient free space on $WORK_PARENT for the extraction budget"
ok "Free-space preflight passed"

if [ "$MODE" = "--restore" ]; then
    case "$WORK_PARENT/" in
        /var/www/.wapt-dr-repository/*) fail "Work directory must be outside repository recovery state" ;;
    esac
    open_restore_repository
fi

WORKDIR=""
cleanup() {
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && [ ! -L "$WORKDIR" ]; then
        rm -rf -- "$WORKDIR"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

WORKDIR="$(mktemp -d -- "${WORK_PARENT%/}/.wapt-dr-restore-check.XXXXXX")" || \
    fail "Unable to create restore check work directory under $WORK_PARENT"
chmod 0700 -- "$WORKDIR" || fail "Unable to secure restore check work directory"
[ "$(stat -c '%u:%a' -- "$WORKDIR")" = "$EUID:700" ] || fail "Work filesystem did not enforce private directory permissions"

# Keep the private staging directory outside the TAR extraction namespace.
EXTRACT_DIR="$WORKDIR/extracted"
BUNDLE="$EXTRACT_DIR/$BUNDLE_ROOT"
if [ "$MODE" = "--restore" ]; then
    mkdir -- "$EXTRACT_DIR" || fail "Unable to create bundle extraction directory"
    echo "Extracting metadata and PostgreSQL dump under $WORK_PARENT..."
    restore_repository_tool metadata "$RESTORE_ARCHIVE" "$BUNDLE" ||
        fail "Metadata and PostgreSQL dump extraction or SHA256 validation failed"
    MANIFEST_PRECHECK="$BUNDLE/manifest.ini"
else
# Validate the backup contract BEFORE extracting the potentially large repository.
MANIFEST_MEMBER="${BUNDLE_ROOT}/manifest.ini"
MANIFEST_PRECHECK="$WORKDIR/.manifest-precheck"

tar -xOf "$ARCHIVE" "$MANIFEST_MEMBER" > "$MANIFEST_PRECHECK" 2>/dev/null || \
    fail "Unable to read manifest.ini directly from archive"
[ -s "$MANIFEST_PRECHECK" ] || fail "manifest.ini is empty"
fi

ini_get_file() {
    file="$1"
    section="$2"
    key="$3"
    awk -v wanted_header="[$section]" -v wanted_key="$key" '
        $0 == wanted_header { active=1; next }
        /^\[/ { active=0 }
        active && $1 == wanted_key && $2 == "=" {
            print $3
            exit
        }
    ' "$file"
}

PRE_FORMAT_VERSION="$(ini_get_file "$MANIFEST_PRECHECK" backup format_version)"
[ "$PRE_FORMAT_VERSION" = "1" ] || \
    fail "Unsupported backup format_version: ${PRE_FORMAT_VERSION:-missing}"

PRE_REPO_INCLUDED="$(ini_get_file "$MANIFEST_PRECHECK" repository included)"
case "$PRE_REPO_INCLUDED" in yes|no) ;; *) fail "Invalid repository included value in manifest: ${PRE_REPO_INCLUDED:-missing}" ;; esac

PRE_REPO_MANIFEST="$(ini_get_file "$MANIFEST_PRECHECK" repository manifest_file)"
[ "$PRE_REPO_MANIFEST" = "metadata/repository-manifest.sha256" ] || \
    fail "Unsupported repository manifest path: ${PRE_REPO_MANIFEST:-missing}"

if [ "$MODE" = "--check" ]; then
    ok "Manifest contract precheck passed before full extraction"
    rm -f -- "$MANIFEST_PRECHECK" || fail "Unable to remove temporary manifest file"
    mkdir -- "$EXTRACT_DIR" || fail "Unable to create bundle extraction directory"
    echo "Extracting bundle for validation under $WORK_PARENT..."
    tar -xf "$ARCHIVE" -C "$EXTRACT_DIR" || fail "Archive extraction failed"
    [ -d "$BUNDLE" ] || fail "Extracted bundle root not found"
    ok "Bundle extracted under $WORK_PARENT"
else
    ok "Manifest contract precheck passed before repository extraction"
fi

for f in \
    manifest.ini \
    SHA256SUMS \
    database/wapt.dump \
    config/waptserver.ini \
    config/nginx/wapt.conf \
    metadata/system.txt \
    metadata/packages.txt \
    metadata/database.txt \
    metadata/repository.txt \
    metadata/repository-manifest.sha256
do
    [ -f "$BUNDLE/$f" ] || fail "Required bundle file missing: $f"
done
ok "Required bundle files are present"

ini_get() {
    section="$1"
    key="$2"
    ini_get_file "$BUNDLE/manifest.ini" "$section" "$key"
}

FORMAT_VERSION="$(ini_get backup format_version)"
[ "$FORMAT_VERSION" = "1" ] || fail "Unsupported bundle format_version: ${FORMAT_VERSION:-missing}"
ok "Bundle format_version=1"

SOURCE_HOST="$(ini_get source hostname)"
SOURCE_FQDN="$(ini_get source fqdn)"
SOURCE_DEBIAN="$(ini_get source debian_major)"
SOURCE_WAPT="$(ini_get source waptserver_version)"
SOURCE_DB_MARKER="$(ini_get source db_version)"
SOURCE_PG_VERSION="$(ini_get database postgresql_version)"
SOURCE_PG_PORT="$(ini_get database postgresql_port)"
PACKAGE_PREFIX="$(ini_get site package_prefix)"
REPO_INCLUDED="$(ini_get repository included)"
REPO_FILES="$(ini_get repository files)"
REPO_MANIFEST_SHA="$(ini_get repository manifest_sha256)"

echo
echo "Source hostname:        ${SOURCE_HOST:-unknown}"
echo "Source FQDN:            ${SOURCE_FQDN:-unknown}"
echo "Source Debian:          ${SOURCE_DEBIAN:-unknown}"
echo "Source WAPT server:     ${SOURCE_WAPT:-unknown}"
echo "Source DB marker:       ${SOURCE_DB_MARKER:-unknown}"
echo "Source PostgreSQL:      ${SOURCE_PG_VERSION:-unknown}"
echo "Source PostgreSQL port: ${SOURCE_PG_PORT:-unknown} (metadata only)"
echo "Package prefix:         ${PACKAGE_PREFIX:-unknown}"
echo "Repository included:    ${REPO_INCLUDED:-unknown}"

CA_KEY="$(ini_get identity clients_signing_key)"
CA_CERT="$(ini_get identity clients_signing_certificate)"
TLS_CERT="$(ini_get identity tls_certificate)"
TLS_KEY="$(ini_get identity tls_key)"

for p in "$CA_KEY" "$CA_CERT" "$TLS_CERT" "$TLS_KEY"; do
    [ -n "$p" ] || fail "Mandatory identity path missing from manifest.ini"
done

for rel in \
    "certificates/client-ca/$(basename "$CA_KEY")" \
    "certificates/client-ca/$(basename "$CA_CERT")" \
    "certificates/server-tls/$(basename "$TLS_CERT")" \
    "certificates/server-tls/$(basename "$TLS_KEY")"
do
    [ -f "$BUNDLE/$rel" ] || fail "Mandatory identity file missing: $rel"
done
ok "Mandatory identity files are present"

REPO_MANIFEST="$BUNDLE/metadata/repository-manifest.sha256"
ACTUAL_REPO_MANIFEST_SHA="$(sha256sum "$REPO_MANIFEST" | awk '{print $1}')"
[ "$ACTUAL_REPO_MANIFEST_SHA" = "$REPO_MANIFEST_SHA" ] || \
    fail "Repository manifest SHA256 mismatch"
ok "Repository manifest SHA256 validated"

if [ "$MODE" = "--restore" ]; then
    [ "$REPO_INCLUDED" = "yes" ] || fail "Source backup does not contain repository payload"
else
case "$REPO_INCLUDED" in
    yes)
        [ -d "$BUNDLE/repository/wapt" ] || \
            fail "Repository declared included but repository directory is missing"

        ACTUAL_REPO_FILES="$(find "$BUNDLE/repository/wapt" -type f | wc -l)"
        [ "$ACTUAL_REPO_FILES" = "$REPO_FILES" ] || \
            fail "Repository file count mismatch: expected $REPO_FILES, got $ACTUAL_REPO_FILES"

        echo "Validating repository file SHA256 manifest..."
        (
            cd "$BUNDLE/repository/wapt" || exit 1
            sha256sum -c "$REPO_MANIFEST"
        ) >/dev/null || fail "Repository file SHA256 validation failed"
        ok "Repository validated: $ACTUAL_REPO_FILES files"
        ;;
    no)
        [ ! -d "$BUNDLE/repository/wapt" ] || \
            fail "Repository declared excluded but repository directory exists"
        ok "Repository correctly excluded"
        ;;
    *)
        fail "Invalid repository included value: ${REPO_INCLUDED:-missing}"
        ;;
esac

echo "Validating bundle SHA256SUMS..."
(
    cd "$BUNDLE" || exit 1
    sha256sum -c SHA256SUMS
) >/dev/null || fail "Bundle SHA256SUMS validation failed"
ok "Bundle SHA256SUMS validated"
fi

pg_restore -l "$BUNDLE/database/wapt.dump" >/dev/null 2>&1 || \
    fail "Database dump is not a valid pg_restore custom-format archive"
ok "Database dump is readable by pg_restore"

if [ "$MODE" = "--restore" ]; then
    echo
    echo "Validating restore target..."

    for tool in dpkg-query pg_lsclusters psql pg_dump pg_restore dropdb createdb runuser systemctl; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required restore tool missing: $tool"
        ok "Restore tool available: $tool"
    done

    [ -r /etc/os-release ] || fail "Unable to read /etc/os-release"
    . /etc/os-release
    TARGET_DEBIAN="${VERSION_ID:-}"
    [ -n "$TARGET_DEBIAN" ] || fail "Unable to determine target Debian version"

    TARGET_WAPT="$(dpkg-query -W -f='${Version}' tis-waptserver 2>/dev/null)" || \
        fail "Target package tis-waptserver is not installed"
    TARGET_SETUP="$(dpkg-query -W -f='${Version}' tis-waptsetup 2>/dev/null)" || \
        fail "Target package tis-waptsetup is not installed"

    systemctl is-active --quiet postgresql || fail "Target PostgreSQL service is not active"

    TARGET_WAPTSERVER_ACTIVE="yes"
    if ! systemctl is-active --quiet waptserver; then
        TARGET_WAPTSERVER_ACTIVE="no"
        warn "Target waptserver service is not active; interrupted-restore state will be checked after PostgreSQL target detection"
    fi

    TARGET_CLUSTERS="$(pg_lsclusters --no-header 2>/dev/null | awk '$4=="online" {print $1 "|" $2 "|" $3 "|" $4 "|" $5}')"
    TARGET_CLUSTER_COUNT="$(printf '%s\n' "$TARGET_CLUSTERS" | awk 'NF {n++} END {print n+0}')"
    [ "$TARGET_CLUSTER_COUNT" -ge 1 ] || fail "No online PostgreSQL cluster found on target"

    TARGET_WAPT_CLUSTERS=""
    while IFS='|' read -r pg_major pg_cluster pg_port pg_status pg_owner; do
        [ -n "$pg_major" ] || continue
        if (cd / && runuser -u postgres -- \
            psql -p "$pg_port" -d wapt -Atqc "SELECT 1;" >/dev/null 2>&1); then
            TARGET_WAPT_CLUSTERS="${TARGET_WAPT_CLUSTERS}${pg_major}|${pg_cluster}|${pg_port}|${pg_status}|${pg_owner}
"
        fi
    done <<EOF
$TARGET_CLUSTERS
EOF

    TARGET_WAPT_CLUSTER_COUNT="$(printf '%s\n' "$TARGET_WAPT_CLUSTERS" | awk 'NF {n++} END {print n+0}')"
    [ "$TARGET_WAPT_CLUSTER_COUNT" -eq 1 ] || \
        fail "Expected exactly one online PostgreSQL cluster containing database wapt, found $TARGET_WAPT_CLUSTER_COUNT"

    TARGET_PG_MAJOR="$(printf '%s\n' "$TARGET_WAPT_CLUSTERS" | awk -F'|' 'NF {print $1; exit}')"
    TARGET_PG_CLUSTER="$(printf '%s\n' "$TARGET_WAPT_CLUSTERS" | awk -F'|' 'NF {print $2; exit}')"
    TARGET_PG_PORT="$(printf '%s\n' "$TARGET_WAPT_CLUSTERS" | awk -F'|' 'NF {print $3; exit}')"
    TARGET_PG_OWNER="$(printf '%s\n' "$TARGET_WAPT_CLUSTERS" | awk -F'|' 'NF {print $5; exit}')"

    RESTORE_STATE="normal"
    if [ "$TARGET_WAPTSERVER_ACTIVE" = "no" ]; then
        TARGET_PUBLIC_TABLE_COUNT="$(cd / && runuser -u postgres -- \
            psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
            "SELECT count(*) FROM pg_tables WHERE schemaname='public';" \
            2>/dev/null)" || fail "Unable to assess interrupted-restore database state"
        if [ "$TARGET_PUBLIC_TABLE_COUNT" = "0" ]; then
            RESTORE_STATE="interrupted-empty"
            warn "Interrupted restore state detected: waptserver inactive and target database has 0 public tables"
            ok "Interrupted empty state accepted; database restore will restart from scratch"
        else
            if validate_post_database_state; then
                RESTORE_STATE="post-database"
                warn "Post-database restore state detected: marker, ownership, ACL and source table counts all match"
                ok "Post-database state accepted; destructive database restore will be skipped"
            else
                RESTORE_STATE="interrupted-partial"
                warn "Interrupted partial restore state detected: waptserver inactive and database does not fully match source backup"
                ok "Interrupted partial state accepted; database restore will restart from scratch"
            fi
        fi
    fi

    [ "$TARGET_PG_OWNER" = "postgres" ] || \
        fail "Target PostgreSQL cluster owner is not postgres: $TARGET_PG_OWNER"

    TARGET_DB_RUNTIME="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
        "SELECT current_database(), current_setting('server_version'), current_setting('port');" \
        2>/dev/null)" || fail "Unable to connect to target WAPT database"

    TARGET_DB_NAME="$(printf '%s\n' "$TARGET_DB_RUNTIME" | awk -F'|' 'NR==1 {print $1}')"
    TARGET_PG_VERSION="$(printf '%s\n' "$TARGET_DB_RUNTIME" | awk -F'|' 'NR==1 {print $2}')"
    TARGET_DB_PORT="$(printf '%s\n' "$TARGET_DB_RUNTIME" | awk -F'|' 'NR==1 {print $3}')"

    [ "$TARGET_DB_NAME" = "wapt" ] || fail "Unexpected target database name: $TARGET_DB_NAME"
    [ "$TARGET_DB_PORT" = "$TARGET_PG_PORT" ] || \
        fail "Target PostgreSQL port mismatch between cluster and database runtime"

    TARGET_DB_OWNER="$(cd / && runuser -u postgres -- \
        psql -p "$TARGET_PG_PORT" -d postgres -Atqc \
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='wapt';" \
        2>/dev/null)" || fail "Unable to determine target WAPT database owner"
    [ "$TARGET_DB_OWNER" = "wapt" ] || \
        fail "Target WAPT database owner is not wapt: ${TARGET_DB_OWNER:-missing}"

    case "$RESTORE_STATE" in
        normal)
            TARGET_DB_MARKER="$(cd / && runuser -u postgres -- \
                psql -p "$TARGET_PG_PORT" -d wapt -Atqc \
                "SELECT value FROM serverattribs WHERE key='db_version';" \
                2>/dev/null)" || fail "Unable to read target WAPT database marker"
            [ -n "$TARGET_DB_MARKER" ] || fail "Target WAPT database marker is empty"
            ;;
        interrupted-empty)
            TARGET_DB_MARKER="<interrupted-empty>"
            warn "Target DB marker check skipped for accepted empty interrupted-restore state"
            ;;
        interrupted-partial)
            TARGET_DB_MARKER="<interrupted-partial>"
            warn "Target DB marker check skipped for accepted partial interrupted-restore state"
            ;;
        post-database)
            TARGET_DB_MARKER="$POST_DB_MARKER"
            ;;
    esac

    echo
    echo "Target Debian:          $TARGET_DEBIAN"
    echo "Target WAPT server:     $TARGET_WAPT"
    echo "Target WAPT setup:      $TARGET_SETUP"
    echo "Target PostgreSQL:      $TARGET_PG_VERSION"
    echo "Target PG cluster:      $TARGET_PG_MAJOR/$TARGET_PG_CLUSTER"
    echo "Target PostgreSQL port: $TARGET_PG_PORT"
    echo "Target DB owner:        $TARGET_DB_OWNER"
    echo "Target DB marker:       $TARGET_DB_MARKER"
    echo "Restore state:          $RESTORE_STATE"
    echo
    record_target_https_identity
    prepare_restore_repository
    if [ "$REPO_STAGE_STATE" = "switched" ]; then
        validate_post_database_state || fail "Repository is already switched but PostgreSQL does not match; retained repository requires review"
        RESTORE_STATE="post-database"
        if [ "$TARGET_WAPTSERVER_ACTIVE" = "yes" ]; then
            validate_and_start_services
            exit 3
        fi
    fi
    ok "Restore target precheck passed"
fi

echo
if [ "$MODE" = "--check" ]; then
    echo "CHECK PASSED"
    echo "No target WAPT data was modified."
else
    echo "RESTORE PRECHECK PASSED"
    echo
    [ "$(id -u)" -eq 0 ] || fail "Root privileges are required to create the target safety backup"
    [ -d /var/www/padit-backups ] || mkdir -p /var/www/padit-backups
    chmod 0700 /var/www/padit-backups || fail "Unable to secure /var/www/padit-backups"

    create_target_safety_backup

    echo
    echo "SAFETY BACKUP PASSED"

    if [ "$RESTORE_STATE" = "post-database" ]; then
        echo
        echo "DATABASE RESTORE SKIPPED"
        echo "A validated post-database restore state was detected."
        echo "The already-restored WAPT database will not be replaced again."
    else
        if [ "$RESTORE_STATE" = "interrupted-empty" ] || [ "$RESTORE_STATE" = "interrupted-partial" ]; then
            echo
            echo "DATABASE RESTORE RESUME"
            echo "Interrupted database state detected; the target database will be recreated from scratch."
        fi
        restore_target_database
        echo
        echo "DATABASE RESTORE PASSED"
        echo "The target WAPT database has been replaced and validated."
    fi

    restore_target_configuration_identity

    echo
    echo "CONFIGURATION / IDENTITY RESTORE PASSED"
    echo "Historical WAPT identity and policy have been restored onto the target runtime."

    restore_target_repository

    echo
    echo "REPOSITORY RESTORE PASSED"
    echo "Historical repository payload and Packages index have been restored."
    echo "Target waptsetup-tis.exe, waptdeploy.exe and signing Root CA were preserved and SHA256-validated."
    echo "waptserver/wapttasks remain stopped intentionally."
    echo "Target nginx configuration was preserved."
    echo "Safety backup retained at: $SAFETY_ARCHIVE"

    validate_and_start_services

    echo
    echo "RESTORE VALIDATION PASSED"
    echo "Database, configuration/identity, repository, TLS identity and local WAPT service startup are validated."
    echo "Production DNS/client reconnection remains behind the explicit pre-production cutover barrier."
    exit 3
fi
