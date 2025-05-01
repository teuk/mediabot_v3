#!/bin/bash
set -euo pipefail

if [ $(id -u) -ne 0 ]; then
	echo "This script must be run as root user"
	exit 1
fi

while getopts 'c:' opt; do
	case $opt in
		c)
			OPTSFOUND=1
			CONFIG_FILE=${OPTARG}
			;;
	esac
done
shift $(( $OPTIND-1 ))

MYSQL_DB_CREATION_SCRIPT=mediabot.sql
SCRIPT_LOGFILE=db_install.log

# +-------------------------------------------------------------------------+
# | Functions                                                               |
# +-------------------------------------------------------------------------+
function messageln {
    if [ ! -z "$1" ]; then
        echo "[$(date +'%d/%m/%Y %H:%M:%S')] $*" | tee -a $SCRIPT_LOGFILE
    fi
}
 
function message {
    if [ ! -z "$1" ]; then
        echo -n "[$(date +'%d/%m/%Y %H:%M:%S')] $* " | tee -a $SCRIPT_LOGFILE
    fi
}
 
function ok_failed {
    if [ ! -z "$1" ] && [ $1 -eq 0 ]; then
        echo "OK" | tee -a $SCRIPT_LOGFILE
    else
    	RETVALUE=$1
      echo -e " Failed. "
      if [ ! -z "$2" ]; then
      	shift
      	echo "$*"
      fi
      echo -e "Installation log is available in $SCRIPT_LOGFILE" | tee -a $SCRIPT_LOGFILE
      exit $RETVALUE
    fi
}

function mysql_create_mediabot_db {
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

messageln "mediabot DB Installation"

message "Check if mysql command is available"
which mysql &>/dev/null
ok_failed $? "You must install MySQL Server and client to continue."

messageln "[+] Stage 1 : Database creation"

# ─── Defaults ──────────────────────────────────────────────────
DEFAULT_DB="mediabot"
DEFAULT_HOST="localhost"
DEFAULT_PORT="3306"
DEFAULT_USER="root"

# ─── Prompt for database name ──────────────────────────────────
read -rp "Enter MySQL database [${DEFAULT_DB}]: " MYSQL_DB
MYSQL_DB=${MYSQL_DB:-$DEFAULT_DB}
if [[ "$MYSQL_DB" == "mysql" ]]; then
    messageln "Mediabot db cannot be 'mysql' !"
    messageln "Exiting."
    exit 1
fi

# ─── Prompt for host ───────────────────────────────────────────
read -rp "Enter MySQL host [${DEFAULT_HOST}]: " HOST_IN
HOST_IN=${HOST_IN:-$DEFAULT_HOST}
# if user stuck with default 'localhost', we'll use the socket
if [[ "$HOST_IN" == "$DEFAULT_HOST" ]]; then
    MYSQL_HOST=""
else
    MYSQL_HOST="$HOST_IN"
fi

# ─── Prompt for port (only if host is non-empty) ───────────────
if [[ -n "${MYSQL_HOST}" ]]; then
    read -rp "Enter MySQL port [${DEFAULT_PORT}]: " MYSQL_PORT
    MYSQL_PORT=${MYSQL_PORT:-$DEFAULT_PORT}
fi

# ─── Prompt for user ───────────────────────────────────────────
read -rp "Enter MySQL root user [${DEFAULT_USER}]: " MYSQL_USER
MYSQL_USER=${MYSQL_USER:-$DEFAULT_USER}

# ─── Prompt for password (silent) ─────────────────────────────
read -rsp "Enter MySQL root password (Hit enter if empty): " MYSQL_PASS
echo

# ─── Connection summary ────────────────────────────────────────
if [[ -n "${MYSQL_HOST}" ]]; then
    conn_info="${MYSQL_HOST}:${MYSQL_PORT}"
else
    conn_info="local socket"
fi
if [[ -n "${MYSQL_PASS}" ]]; then
    pass_info="password set"
else
    pass_info="empty password"
fi
messageln "Database '$MYSQL_DB' creation using (${conn_info}) user '$MYSQL_USER' (${pass_info})"

# ─── Build MYSQL_PARAMS ────────────────────────────────────────
MYSQL_PARAMS="-u ${MYSQL_USER}"
if [[ -n "${MYSQL_HOST}" ]]; then
    MYSQL_PARAMS+=" -h ${MYSQL_HOST} -P ${MYSQL_PORT}"
fi
if [[ -n "${MYSQL_PASS}" ]]; then
    MYSQL_PARAMS+=" -p${MYSQL_PASS}"
fi

echo "MYSQL_PARAMS=${MYSQL_PARAMS}"

# ─── Test connection ───────────────────────────────────────────
message "Check connection to MySQL DB"
if echo "exit" | mysql ${MYSQL_PARAMS}; then
    ok_failed 0
else
    ok_failed 1
fi
 
CHECK_DB_EXISTENCE=$(mysql $MYSQL_PARAMS --skip-column-names -e "SHOW DATABASES LIKE '$MYSQL_DB'")
if [ "$CHECK_DB_EXISTENCE" == "$MYSQL_DB" ]; then
    messageln "Database $MYSQL_DB exists."
    message "Do you want to re-create it ? (y/n) (WARNING THIS WILL 'DROP' existing $MYSQL_DB database and lose all data !) [n] : "
    read myresp
    if [ ! -z "$myresp" ] && [ "$myresp" == "y" ]; then
        mysql_create_mediabot_db
    else
        messageln "Database creation skipped"
    fi
else
    mysql_create_mediabot_db
fi

messageln "[+] Stage 2 : Database user creation"
MYSQL_DB_USER=mediabot
message "Enter MySQL database user (not root) (Hit enter for 'mediabot') : "
read myresp
if [ ! -z "$myresp" ]; then
    MYSQL_DB_USER=$myresp
fi
 
MYSQL_DB_PASS=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w12 | head -n1)
message "Enter MySQL database user pass (Hit enter for '$MYSQL_DB_PASS') : "
read myresp
if [ ! -z "$myresp" ]; then
    MYSQL_DB_PASS=$myresp
fi

if [ -z "$MYSQL_HOST" ]; then
    IPADDR="localhost"
    MYSQL_PORT="3306"
elif [ "$MYSQL_HOST" != "localhost" ] && [ "$MYSQL_HOST" != "127.0.0.1" ]; then
    IPADDR=
    messageln "MySQL host $MYSQL_HOST is external we need to determine our ip address"
    message "Check if dig command is available"
    which dig &>/dev/null
    if [ $? -eq 0 ]; then
        IPADDR=$(dig +short myip.opendns.com @resolver1.opendns.com)
        echo "OK IPADDR=$IPADDR"
    else
        echo "Failed."
        message "dig is not available trying with curl"
        which curl &>/dev/null
        if [ $? -eq 0 ]; then
            IPADDR=$(curl -f -s checkip.dyndns.org | awk '{ print $NF }' | sed -e 's/<\/body><\/html>//')
            echo "OK IPADDR=$IPADDR"
        else
            echo "Failed."
            message "curl is not available, finally trying to guess from ip settings"
            IPADDR=$(ip route get 8.8.8.8 | awk '/8.8.8.8/ {print $NF}')
            if [ ! -z "$IPADDR" ]; then
                echo "OK IPADDR=$IPADDR"
            fi
        fi
    fi
    if [ -z "$IPADDR" ]; then
        echo "Could not determine our ip address"
        message "Enter it manually (be sure of what you are typing, not checking) : "
        read myresp
        while [ -z "$myresp" ]
            do
                echo -n "ip address cannot be empty. Enter our ip address : "
                read myresp
            done
    fi
else
    IPADDR=$MYSQL_HOST
fi
 
message "Grant privileges on $MYSQL_DB to $MYSQL_DB_USER with user password"
if [ "$IPADDR" == "127.0.0.1" ]; then
    AUTH_HOST="localhost"
else
    AUTH_HOST=$IPADDR
fi
echo "GRANT ALL PRIVILEGES ON $MYSQL_DB.* TO '$MYSQL_DB_USER'@'$AUTH_HOST' IDENTIFIED BY '$MYSQL_DB_PASS'" | mysql ${MYSQL_PARAMS}
ok_failed $?
 
message "Flush privileges"
echo "FLUSH PRIVILEGES" | mysql ${MYSQL_PARAMS}
ok_failed $?
 
MYSQL_PARAMS="-h $MYSQL_HOST -P $MYSQL_PORT -u ${MYSQL_DB_USER} -p${MYSQL_DB_PASS}"
message "Check connection to MySQL DB with defined user $MYSQL_DB_USER"
echo "exit" | mysql $MYSQL_PARAMS $MYSQL_DB
ok_failed $?

messageln "Database configuration completed."

if [ ! -z "$CONFIG_FILE" ] && [ -w "$CONFIG_FILE" ]; then
	message "Configure $CONFIG_FILE [mysql] parameters"
	echo "[mysql]
MAIN_PROG_DDBNAME=$MYSQL_DB
MAIN_PROG_DBUSER=$MYSQL_DB_USER
MAIN_PROG_DBPASS=$MYSQL_DB_PASS
MAIN_PROG_DBHOST=$MYSQL_HOST
MAIN_PROG_DBPORT=$MYSQL_PORT

">>$CONFIG_FILE
 ok_failed $?
fi