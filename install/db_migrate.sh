#!/usr/bin/env bash
#
# Mediabot v3 database migration helper
#
# Usage:
#   ./install/db_migrate.sh [--defaults-extra-file FILE] <database> <migration.sql> [mysql_user]
#
# Examples:
#   ./install/db_migrate.sh mediabotv3 install/migrations/20260502_user_seen.sql root
#   ./install/db_migrate.sh --defaults-extra-file /root/.mediabot-mysql.cnf mediabotv3 install/migrations/20260816_achievements_db.sql
#
# The script intentionally uses the mysql client with SOURCE and explicit
# utf8mb4 settings instead of shell redirection.
#

set -euo pipefail
umask 077

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULTS_EXTRA_FILE=""

usage() {
    cat >&2 <<EOF_USAGE
Usage:
  $0 [--defaults-extra-file FILE] <database> <migration.sql> [mysql_user]

Examples:
  $0 mediabotv3 install/migrations/20260502_user_seen.sql root
  $0 --defaults-extra-file /root/.mediabot-mysql.cnf mediabotv3 install/migrations/20260816_achievements_db.sql

Notes:
  - The migration file must be inside install/migrations/
  - Import is done through mysql SOURCE with utf8mb4 explicitly set
  - Without --defaults-extra-file, mysql keeps the historical interactive -p prompt
  - --defaults-extra-file must be a private regular file (no group/other permissions)
EOF_USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --defaults-extra-file)
            [ "$#" -ge 2 ] || { echo "ERROR: --defaults-extra-file requires a file" >&2; exit 2; }
            DEFAULTS_EXTRA_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage
    exit 1
fi

DB_NAME="$1"
MIGRATION="$2"
MYSQL_USER="${3:-root}"

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "ERROR: invalid database name '$DB_NAME'" >&2
    exit 1
fi

case "$MIGRATION" in
    install/migrations/*.sql)
        MIGRATION_PATH="${APP_DIR}/${MIGRATION}"
        ;;
    "$APP_DIR"/install/migrations/*.sql)
        MIGRATION_PATH="$MIGRATION"
        ;;
    *)
        echo "ERROR: migration must be under install/migrations/" >&2
        exit 1
        ;;
esac

if [ ! -f "$MIGRATION_PATH" ]; then
    echo "ERROR: migration file not found: $MIGRATION_PATH" >&2
    exit 1
fi

case "$MIGRATION_PATH" in
    *$'\n'*|*";"*|*"'"*|*'"'*)
        echo "ERROR: unsafe migration path: $MIGRATION_PATH" >&2
        exit 1
        ;;
esac

MYSQL_CMD=(mysql)
if [ -n "$DEFAULTS_EXTRA_FILE" ]; then
    if [ ! -f "$DEFAULTS_EXTRA_FILE" ] || [ -L "$DEFAULTS_EXTRA_FILE" ]; then
        echo "ERROR: --defaults-extra-file must reference an existing regular non-symlink file" >&2
        exit 1
    fi

    DEFAULTS_MODE="$(stat -c '%a' "$DEFAULTS_EXTRA_FILE")" || {
        echo "ERROR: cannot read mode for defaults file" >&2
        exit 1
    }
    if (( (8#$DEFAULTS_MODE & 077) != 0 )); then
        echo "ERROR: --defaults-extra-file must not be readable/writable/executable by group or others" >&2
        exit 1
    fi

    if [ "$#" -eq 3 ]; then
        echo "ERROR: do not combine mysql_user with --defaults-extra-file; keep credentials in the private option file" >&2
        exit 1
    fi

    # mysql/mariadb requires defaults-file options before ordinary options.
    MYSQL_CMD+=("--defaults-extra-file=$DEFAULTS_EXTRA_FILE")
    MYSQL_AUTH_LABEL="defaults-extra-file"
else
    MYSQL_CMD+=(-u "$MYSQL_USER" -p)
    MYSQL_AUTH_LABEL="interactive user $MYSQL_USER"
fi
MYSQL_CMD+=(--default-character-set=utf8mb4 --show-warnings)

echo "Database:  $DB_NAME"
echo "Migration: $MIGRATION_PATH"
echo "MySQL auth: $MYSQL_AUTH_LABEL"
echo

"${MYSQL_CMD[@]}" "$DB_NAME" --execute="
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SOURCE $MIGRATION_PATH;
"

echo
echo "Migration applied successfully."
