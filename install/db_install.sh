#!/bin/bash
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

MYSQL_DB_CREATION_SCRIPT=mediabot.sql
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
        echo "DROP DATABASE IF EXISTS $MYSQL_DB" | mysql $MYSQL_PARAMS
        ok_failed $?
    fi
    message "Create database $MYSQL_DB"
    echo "CREATE DATABASE $MYSQL_DB" | mysql $MYSQL_PARAMS
    ok_failed $?

    message "Create database structure"
    if [ -f $MYSQL_DB_CREATION_SCRIPT ]; then
        cat $MYSQL_DB_CREATION_SCRIPT | mysql $MYSQL_PARAMS $MYSQL_DB
        ok_failed $?
    else
        messageln "Could not find $MYSQL_DB_CREATION_SCRIPT"
        exit 1
    fi

    messageln "DB Tables"
    echo "SHOW TABLES" | mysql $MYSQL_PARAMS $MYSQL_DB
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

# build params
MYSQL_PARAMS="-u${MYSQL_USER}"
[[ -n "$MYSQL_HOST" ]] && MYSQL_PARAMS+=" -h${MYSQL_HOST} -P${MYSQL_PORT}"
[[ -n "$MYSQL_PASS" ]] && MYSQL_PARAMS+=" -p${MYSQL_PASS}"

echo "MYSQL_PARAMS=${MYSQL_PARAMS}"

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

# ─── 1) CREATE (or ALTER) & GRANT & FLUSH in one shot ───────────────────
messageln "Creating/updating '${MYSQL_DB_USER}'@'${AUTH_HOST}' and granting on ${MYSQL_DB}"
mysql ${MYSQL_PARAMS} -e "
  CREATE USER IF NOT EXISTS '${MYSQL_DB_USER}'@'${AUTH_HOST}'
    IDENTIFIED BY '${MYSQL_DB_PASS}';
  ALTER USER '${MYSQL_DB_USER}'@'${AUTH_HOST}'
    IDENTIFIED BY '${MYSQL_DB_PASS}';
  GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* 
    TO '${MYSQL_DB_USER}'@'${AUTH_HOST}';
  FLUSH PRIVILEGES;
"
ok_failed $? "Errors while creating/granting for user ${MYSQL_DB_USER}@${AUTH_HOST}"

# ─── 2) VERIFY new user can connect ──────────────────────────────────────
USER_MYSQL_PARAMS="-u${MYSQL_DB_USER} -p${MYSQL_DB_PASS}"
[[ -n "$MYSQL_HOST" ]] && USER_MYSQL_PARAMS+=" -h${MYSQL_HOST} -P${MYSQL_PORT}"

messageln "Verifying connection as ${MYSQL_DB_USER}…"
if ! echo "SELECT 1;" | mysql ${USER_MYSQL_PARAMS} ${MYSQL_DB}; then
    ok_failed $? "User ${MYSQL_DB_USER} failed to connect"
    messageln "Dropping user '${MYSQL_DB_USER}'@'${AUTH_HOST}' due to verification failure"
    mysql ${MYSQL_PARAMS} -e "DROP USER '${MYSQL_DB_USER}'@'${AUTH_HOST}';"
    ok_failed $? "Failed to drop ${MYSQL_DB_USER}@${AUTH_HOST} after failure"
fi
ok_failed 0

messageln "Database user creation completed."
messageln "User '${MYSQL_DB_USER}'@'${AUTH_HOST}' created with password '${MYSQL_DB_PASS}'"



# +-------------------------------------------------------------------------+
# | [5] Write config file if asked                                           |
# +-------------------------------------------------------------------------+
if [[ -n "${CONFIG_FILE:-}" && -w "$CONFIG_FILE" ]]; then
    message "Configure $CONFIG_FILE [mysql] parameters"
    cat >>"$CONFIG_FILE" <<EOF

[mysql]
MAIN_PROG_DDBNAME=$MYSQL_DB
MAIN_PROG_DBUSER=$MYSQL_DB_USER
MAIN_PROG_DBPASS=$MYSQL_DB_PASS
MAIN_PROG_DBHOST=$MYSQL_HOST
MAIN_PROG_DBPORT=$MYSQL_PORT

EOF
    ok_failed $?
fi
messageln "Configuration file $CONFIG_FILE updated."