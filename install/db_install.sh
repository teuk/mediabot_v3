#!/bin/bash

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
MYSQL_DB=mediabot
message "Enter MySQL database (Hit enter for 'mediabot') : "
read myresp
if [ ! -z "$myresp" ]; then
    if [ $myresp == "mysql" ]; then
        messageln "Mediabot db cannot be $myresp !"
        messageln "Exiting."
        exit 1;
    fi
    MYSQL_DB=$myresp
fi

MYSQL_HOST=localhost
message "Enter MySQL host (Hit enter for localhost) : "
read myresp
if [ ! -z "$myresp" ]; then
    if [ "$myresp" == "localhost" ]; then
        # Did you know that mysql -h localhost -P 1234 will assume 3306 ?
        MYSQL_HOST=127.0.0.1
    else
        MYSQL_HOST=$myresp
    fi
fi

if [ ! -z "${MYSQL_HOST}" ]; then
    MYSQL_PORT=3306
    message "Enter MySQL port (Hit enter for '3306') : "
    read myresp
    if [ ! -z "$myresp" ]; then
        MYSQL_PORT=$myresp
    fi
fi
 
MYSQL_USER=root
message "Enter MySQL root user (Hit enter for 'root') : "
read myresp
if [ ! -z "$myresp" ]; then
    MYSQL_USER=$myresp
fi
 
unset MYSQL_PASS
prompt="[$(date +'%d/%m/%Y %H:%M:%S')] Enter MySQL root password (Hit enter if empty) : "
while IFS= read -p "$prompt" -r -s -n 1 char
do
    if [[ $char == $'\0' ]]
    then
        break
    fi
    prompt='*'
    MYSQL_PASS+="$char"
done
echo
 
MYSQL_CONNECTION_MESSAGE="Database $MYSQL_DB creation using"
if [ ! -z "$MYSQL_HOST" ]; then
    MYSQL_CONNECTION_MESSAGE="$MYSQL_CONNECTION_MESSAGE ($MYSQL_HOST:$MYSQL_PORT)"
else
    MYSQL_CONNECTION_MESSAGE="$MYSQL_CONNECTION_MESSAGE (local socket)"
fi
 
MYSQL_CONNECTION_MESSAGE="$MYSQL_CONNECTION_MESSAGE ($MYSQL_USER"
if [ -z "$MYSQL_PASS" ]; then
    MYSQL_CONNECTION_MESSAGE="$MYSQL_CONNECTION_MESSAGE <empty password>)"
else
    MYSQL_CONNECTION_MESSAGE="$MYSQL_CONNECTION_MESSAGE <password set>)"
fi
 
messageln "$MYSQL_CONNECTION_MESSAGE"
if [ ! -z "$MYSQL_HOST" ]; then
    MYSQL_PARAMS="-h $MYSQL_HOST -P $MYSQL_PORT "
fi
MYSQL_PARAMS="$MYSQL_PARAMS -u ${MYSQL_USER} "
if [ ! -z "$MYSQL_PASS" ]; then
    MYSQL_PARAMS="$MYSQL_PARAMS -p${MYSQL_PASS} "
fi
 
message "Check connection to MySQL DB"
echo "exit" | mysql $MYSQL_PARAMS
ok_failed $?
 
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