#!/usr/bin/env bash
#
# Mediabot v3 database migration helper
#
# Usage:
#   ./install/db_migrate.sh <database> <migration.sql> [mysql_user]
#
# Example:
#   ./install/db_migrate.sh mediabotv3 install/migrations/20260502_user_seen.sql root
#
# The script intentionally uses the mysql client with SOURCE and explicit
# utf8mb4 settings instead of shell redirection.
#

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat >&2 <<EOF_USAGE
Usage:
  $0 <database> <migration.sql> [mysql_user]

Examples:
  $0 mediabotv3 install/migrations/20260502_user_seen.sql root
  $0 mediabotv3 install/migrations/20260502_channel_ban.sql mediabot

Notes:
  - The migration file must be inside install/migrations/
  - Import is done through mysql SOURCE with utf8mb4 explicitly set
EOF_USAGE
}

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

echo "Database:  $DB_NAME"
echo "Migration: $MIGRATION_PATH"
echo "MySQL user: $MYSQL_USER"
echo

mysql --default-character-set=utf8mb4 -u "$MYSQL_USER" -p "$DB_NAME" --show-warnings --execute="
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SOURCE $MIGRATION_PATH;
"

echo
echo "Migration applied successfully."
