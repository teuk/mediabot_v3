#!/bin/bash

# mb378-R1: update [mysql] atomically through configure_config.pl.
# mb511-B1: fix dependency-free SQL literal escaping and idempotent user rollback.
# chatGPT you should have told me to comment this but keep searching :) and yes you removed mysql_create_mediabot_db function...
#set -euo pipefail

# +-------------------------------------------------------------------------+
# | [1] Startup & opts                                                      |
# +-------------------------------------------------------------------------+
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root user"
    exit 1
fi

CONFIG_FILE=
while getopts 'c:' opt; do
    case $opt in
        c) CONFIG_FILE=$OPTARG ;;
    esac
done
shift $((OPTIND-1))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MYSQL_DB_CREATION_SCRIPT="${SCRIPT_DIR}/mediabot.sql"
SCRIPT_LOGFILE=db_install.log

# +-------------------------------------------------------------------------+
# | [2] Helpers                                                              |
# +-------------------------------------------------------------------------+
messageln(){
    [ -n "${1-}" ] && echo "[$(date +'%d/%m/%Y %H:%M:%S')] $*" | tee -a "$SCRIPT_LOGFILE"
}

message(){
    [ -n "${1-}" ] && echo -n "[$(date +'%d/%m/%Y %H:%M:%S')] $* " | tee -a "$SCRIPT_LOGFILE"
}

ok_failed(){
    local rc=$1
    if [ "$rc" -eq 0 ]; then
        echo "OK" | tee -a "$SCRIPT_LOGFILE"
    else
        echo -e "Failed." | tee -a "$SCRIPT_LOGFILE"
        [ $# -gt 1 ] && shift && echo "$*" | tee -a "$SCRIPT_LOGFILE"
        echo "Installation log is available in $SCRIPT_LOGFILE" | tee -a "$SCRIPT_LOGFILE"
        exit "$rc"
    fi
}

ts(){ date '+[%d/%m/%Y %H:%M:%S]'; }

mysql_create_mediabot_db() {
    if [ "$CHECK_DB_EXISTENCE" == "$MYSQL_DB" ]; then
        message "Drop database $MYSQL_DB"
        printf "DROP DATABASE IF EXISTS \`%s\`;\n" "$MYSQL_DB" | mysql ${MYSQL_PARAMS}
        ok_failed $?
    fi
    message "Create database $MYSQL_DB"
    printf "CREATE DATABASE \`%s\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n" "$MYSQL_DB" | mysql ${MYSQL_PARAMS}
    ok_failed $?

    message "Create database structure"
    if [ -f "$MYSQL_DB_CREATION_SCRIPT" ]; then
        mysql ${MYSQL_PARAMS} "$MYSQL_DB" --show-warnings --execute="
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;
SOURCE ${MYSQL_DB_CREATION_SCRIPT};
"
        ok_failed $?
    else
        messageln "Could not find $MYSQL_DB_CREATION_SCRIPT"
        exit 1
    fi

    messageln "DB Tables"
    echo "SHOW TABLES" | mysql ${MYSQL_PARAMS} "$MYSQL_DB"
    if [ $? -ne 0 ]; then
        echo -e "Failed.\nInstallation log is available in $SCRIPT_LOGFILE" | tee -a $SCRIPT_LOGFILE
    fi
}

# +-------------------------------------------------------------------------+
# | [3] Stage 1: Database creation                                           |
# +-------------------------------------------------------------------------+
messageln "[+] Stage 1 : Database creation"

# defaults
DEFAULT_DB="mediabot"
DEFAULT_HOST="localhost"
DEFAULT_PORT="3306"
DEFAULT_USER="root"

# DB name
read -rp "$(ts) Enter MySQL database [${DEFAULT_DB}]: " MYSQL_DB
MYSQL_DB=${MYSQL_DB:-$DEFAULT_DB}
if [[ "$MYSQL_DB" == "mysql" ]]; then
    messageln "Mediabot db cannot be 'mysql'!"
    messageln "Exiting."
    exit 1
fi

if [[ ! "$MYSQL_DB" =~ ^[A-Za-z0-9_]+$ ]]; then
    messageln "Invalid database name '$MYSQL_DB'. Use only letters, numbers and underscore."
    exit 1
fi

# host
read -rp "$(ts) Enter MySQL host [${DEFAULT_HOST}]: " HOST_IN
HOST_IN=${HOST_IN:-$DEFAULT_HOST}
if [[ "$HOST_IN" == "$DEFAULT_HOST" ]]; then
    MYSQL_HOST=""
else
    MYSQL_HOST="$HOST_IN"
fi

# port
if [[ -n "$MYSQL_HOST" ]]; then
    read -rp "$(ts) Enter MySQL port [${DEFAULT_PORT}]: " MYSQL_PORT
    MYSQL_PORT=${MYSQL_PORT:-$DEFAULT_PORT}
fi

# user
read -rp "$(ts) Enter MySQL root user [${DEFAULT_USER}]: " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-$DEFAULT_USER}

# password (silent)
read -rsp "$(ts) Enter MySQL root password (Hit enter if empty): " MYSQL_PASS
echo

# summary
if [[ -n "$MYSQL_HOST" ]]; then
    conn_info="$MYSQL_HOST:$MYSQL_PORT"
else
    conn_info="local socket"
fi
pass_info=$([[ -n "$MYSQL_PASS" ]] && echo "password set" || echo "empty password")
messageln "Database '$MYSQL_DB' creation using (${conn_info}) user '$MYSQL_USER' (${pass_info})"

# build root MySQL client option file.
# This avoids exposing passwords in process arguments.
MYSQL_ROOT_CNF="$(mktemp /tmp/mediabot_mysql_root.XXXXXX.cnf)"
chmod 600 "$MYSQL_ROOT_CNF"

{
    echo "[client]"
    echo "user=${MYSQL_USER}"
    [[ -n "$MYSQL_PASS" ]] && echo "password=${MYSQL_PASS}"
    [[ -n "$MYSQL_HOST" ]] && echo "host=${MYSQL_HOST}"
    [[ -n "$MYSQL_HOST" ]] && echo "port=${MYSQL_PORT}"
    echo "default-character-set=utf8mb4"
} > "$MYSQL_ROOT_CNF"

MYSQL_PARAMS="--defaults-extra-file=${MYSQL_ROOT_CNF}"

cleanup_mysql_cnf() {
    rm -f "${MYSQL_ROOT_CNF:-}" "${MYSQL_APP_CNF:-}" "${CONFIG_OVERLAY:-}"
}
trap cleanup_mysql_cnf EXIT

messageln "MySQL root connection parameters prepared (password hidden)"

# test connection
message "Check connection to MySQL DB"
echo exit | mysql ${MYSQL_PARAMS}
ok_failed $?

# check existence
CHECK_DB_EXISTENCE=$(mysql ${MYSQL_PARAMS} --skip-column-names -e "SHOW DATABASES LIKE '$MYSQL_DB'")
if [[ "$CHECK_DB_EXISTENCE" == "$MYSQL_DB" ]]; then
    messageln "Database $MYSQL_DB exists."
    message "Re-create it? (y/N) [N]: "
    read -r REPLY </dev/tty
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        mysql_create_mediabot_db
    else
        messageln "Database creation skipped"
    fi
else
    mysql_create_mediabot_db
fi

# +-------------------------------------------------------------------------+
# | [4] Stage 2: Database user creation                                     |
# +-------------------------------------------------------------------------+
messageln "[+] Stage 2 : Database user creation"

# ─── Defaults & random password ──────────────────────────────────────────
DEFAULT_DB_USER="mediabot"
DEFAULT_DB_PASS=$(tr -dc '[:alnum:]' </dev/urandom | fold -w12 | head -n1)

# ─── Prompt for database user ───────────────────────────────────────────
read -rp "$(ts) Enter MySQL database user (not root) [${DEFAULT_DB_USER}]: " MYSQL_DB_USER
MYSQL_DB_USER=${MYSQL_DB_USER:-$DEFAULT_DB_USER}

if [[ ! "$MYSQL_DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
    messageln "Invalid database user '$MYSQL_DB_USER'. Use only letters, numbers and underscore."
    exit 1
fi

# ─── Prompt for database user password ──────────────────────────────────
read -rsp "$(ts) Enter MySQL database user pass [${DEFAULT_DB_PASS}]: " MYSQL_DB_PASS
echo
MYSQL_DB_PASS=${MYSQL_DB_PASS:-$DEFAULT_DB_PASS}

# ─── Determine AUTH_HOST ────────────────────────────────────────────────
if [[ -z "$MYSQL_HOST" || "$MYSQL_HOST" == "127.0.0.1" ]]; then
    AUTH_HOST="localhost"
else
    AUTH_HOST=${IPADDR:-$MYSQL_HOST}
fi

if [[ ! "$AUTH_HOST" =~ ^[A-Za-z0-9_.:%-]+$ ]]; then
    messageln "Invalid MySQL grant host '$AUTH_HOST'."
    exit 1
fi

# mb481-B1: quote SQL string literals explicitly before embedding user-provided
# values in CREATE/ALTER USER. The default generated password is alphanumeric,
# but a custom password containing a quote/backslash must not break the SQL.
sql_string_literal() {
    local v="$1"
    case "$v" in
        *$'\n'*|*$'\r'*)
            messageln "Invalid SQL string literal: newline characters are not allowed."
            exit 1
            ;;
    esac
    # Keep this dependency-free: db_install.sh runs before CPAN and must not
    # rely on sed quoting rules.  Escape MySQL/MariaDB SQL string literals with
    # Bash parameter expansion: backslashes are doubled and single quotes are
    # represented as two adjacent single quotes.
    local escaped="$v"
    escaped=${escaped//\\/\\\\}
    escaped=${escaped//\'/\'\'}
    printf "'%s'" "$escaped"
}

# Command substitution runs the helper in a subshell.  Check every return code
# explicitly so a rejected newline-bearing value cannot silently become an
# empty SQL literal when this installer is running without `set -e`.
MYSQL_DB_USER_SQL=$(sql_string_literal "$MYSQL_DB_USER") || exit 1
AUTH_HOST_SQL=$(sql_string_literal "$AUTH_HOST") || exit 1
MYSQL_DB_PASS_SQL=$(sql_string_literal "$MYSQL_DB_PASS") || exit 1

# ─── 1) CREATE (or ALTER) & GRANT & FLUSH in one shot ───────────────────
messageln "Creating/updating '${MYSQL_DB_USER}'@'${AUTH_HOST}' and granting on ${MYSQL_DB}"
mysql ${MYSQL_PARAMS} <<SQL
CREATE USER IF NOT EXISTS ${MYSQL_DB_USER_SQL}@${AUTH_HOST_SQL}
  IDENTIFIED BY ${MYSQL_DB_PASS_SQL};
ALTER USER ${MYSQL_DB_USER_SQL}@${AUTH_HOST_SQL}
  IDENTIFIED BY ${MYSQL_DB_PASS_SQL};
GRANT ALL PRIVILEGES ON \`${MYSQL_DB}\`.*
  TO ${MYSQL_DB_USER_SQL}@${AUTH_HOST_SQL};
FLUSH PRIVILEGES;
SQL
ok_failed $? "Errors while creating/granting for user ${MYSQL_DB_USER}@${AUTH_HOST}"

# ─── 2) VERIFY new user can connect ──────────────────────────────────────
MYSQL_APP_CNF="$(mktemp /tmp/mediabot_mysql_app.XXXXXX.cnf)"
chmod 600 "$MYSQL_APP_CNF"

{
    echo "[client]"
    echo "user=${MYSQL_DB_USER}"
    echo "password=${MYSQL_DB_PASS}"
    [[ -n "$MYSQL_HOST" ]] && echo "host=${MYSQL_HOST}"
    [[ -n "$MYSQL_HOST" ]] && echo "port=${MYSQL_PORT}"
    echo "default-character-set=utf8mb4"
} > "$MYSQL_APP_CNF"

USER_MYSQL_PARAMS="--defaults-extra-file=${MYSQL_APP_CNF}"

messageln "Verifying connection as ${MYSQL_DB_USER}…"
echo "SELECT 1;" | mysql ${USER_MYSQL_PARAMS} "${MYSQL_DB}"
verify_rc=$?

if [ "$verify_rc" -ne 0 ]; then
    echo -e "Failed." | tee -a "$SCRIPT_LOGFILE"
    echo "User ${MYSQL_DB_USER} failed to connect" | tee -a "$SCRIPT_LOGFILE"
    messageln "Dropping user '${MYSQL_DB_USER}'@'${AUTH_HOST}' due to verification failure"
    # Reuse the already validated/quoted literals and make rollback idempotent.
    mysql ${MYSQL_PARAMS} -e "DROP USER IF EXISTS ${MYSQL_DB_USER_SQL}@${AUTH_HOST_SQL};"
    ok_failed $? "Failed to drop ${MYSQL_DB_USER}@${AUTH_HOST} after failure"
    echo "Installation log is available in $SCRIPT_LOGFILE" | tee -a "$SCRIPT_LOGFILE"
    exit "$verify_rc"
fi
ok_failed 0

messageln "Database user creation completed."
messageln "User '${MYSQL_DB_USER}'@'${AUTH_HOST}' created/updated (password hidden)"



# +-------------------------------------------------------------------------+
# | [5] Update config atomically if asked                                    |
# +-------------------------------------------------------------------------+
if [[ -n "${CONFIG_FILE:-}" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        messageln "Configuration file $CONFIG_FILE does not exist."
        exit 1
    fi

    if [[ ! -w "$CONFIG_FILE" ]]; then
        messageln "Configuration file $CONFIG_FILE is not writable."
        exit 1
    fi

    CONFIG_HELPER="${SCRIPT_DIR}/configure_config.pl"
    SAMPLE_CONF="${SCRIPT_DIR}/../mediabot.sample.conf"
    if [[ ! -x "$CONFIG_HELPER" || ! -f "$SAMPLE_CONF" ]]; then
        messageln "Atomic configuration helper or sample file is missing."
        exit 1
    fi

    CONFIG_DB_HOST="${HOST_IN:-localhost}"
    CONFIG_DB_PORT="${MYSQL_PORT:-3306}"
    CONFIG_OVERLAY="$(mktemp /tmp/mediabot_db_config.XXXXXX)"
    chmod 600 "$CONFIG_OVERLAY"
    cat >"$CONFIG_OVERLAY" <<EOF
mysql.MAIN_PROG_DDBNAME=$MYSQL_DB
mysql.MAIN_PROG_DBUSER=$MYSQL_DB_USER
mysql.MAIN_PROG_DBPASS=$MYSQL_DB_PASS
mysql.MAIN_PROG_DBHOST=$CONFIG_DB_HOST
mysql.MAIN_PROG_DBPORT=$CONFIG_DB_PORT
mysql.CHARSET_MODE=utf8mb4
EOF

    message "Update $CONFIG_FILE [mysql] parameters atomically"
    perl "$CONFIG_HELPER" \
        --sample "$SAMPLE_CONF" \
        --config "$CONFIG_FILE" \
        --mode merge \
        --overlay "$CONFIG_OVERLAY" \
        --backup-dir "$(dirname "$CONFIG_FILE")/config-backups"
    update_rc=$?
    rm -f "$CONFIG_OVERLAY"
    ok_failed "$update_rc"
    messageln "Configuration file $CONFIG_FILE updated."
    messageln "No duplicate [mysql] section was appended."
else
    messageln "No configuration file requested; skipping config update."
fi
