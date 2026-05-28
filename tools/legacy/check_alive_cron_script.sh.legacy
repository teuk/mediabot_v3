#!/bin/bash

# +-------------------------------------------------------------------------+
# | check_alive_cron_script.sh : Mediabot crontab script                    |
# +-------------------------------------------------------------------------+

# +-------------------------------------------------------------------------+
# | Settings (set full mediabot.pl path and crontab log file                |
# +-------------------------------------------------------------------------+
SCRIPT_LOGFILE=crontab.log
BOT_BIN=/home/mediabot/mediabot_v3/mediabot.pl
RETVAL=0

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

function usage {
	if [ ! -z "$1" ]; then
		messageln "Error : $1"
  fi
  messageln "$(basename $0) help:"
  messageln "-h                         show this help"
  messageln "-s <configuration_file>    specify configuration file"
  exit 1
}

# +-------------------------------------------------------------------------+
# | MAIN                                                                    |
# +-------------------------------------------------------------------------+

# This script must not be run as root user
if [ $(id -u) -eq 0 ]; then
	messageln "This script must not be run as root user"
	messageln "You should add this script to mediabot user crontab"
	exit 1
fi

# +-------------------------------------------------------------------------+
# | Check command line parameters                                           |
# +-------------------------------------------------------------------------+
while getopts 's:h' opt; do
        case $opt in
                s)			OPTSFOUND=1
                				CONF_FILE=${OPTARG}
                        ;;
                h)			OPTSFOUND=1
                        usage
                        ;;
                \?)			usage "Invalid option"
                        ;;
        esac
done
shift $(( $OPTIND-1 ))

if [ ! -z "$CONF_FILE" ]; then
	if [ ! -f $CONF_FILE ]; then
		usage "$CONF_FILE does not exist"
	fi
else
	usage "Missing configuration file, $(basename $0) -s <configuration_file>"
fi

# +-------------------------------------------------------------------------+
# | Check if bot is running                                                 |
# +-------------------------------------------------------------------------+
BOT_PID_FILE=$(grep ^MAIN_PID_FILE $CONF_FILE | awk -F= '{print $2}')
if [ -z "$BOT_PID_FILE" ]; then
	messageln "Could not get BOT_PID_FILE from $CONF_FILE"
	exit 1
elif [ ! -f $BOT_PID_FILE ]; then
	messageln "$BOT_PID_FILE does not exist"
	exit 1
else
	messageln "Found PID File from $CONF_FILE"
	BOT_PID=$(cat $BOT_PID_FILE 2>/dev/null)
	if [ ! -z "$BOT_PID" ]; then
		messageln "BOT_PID is $BOT_PID"
		BOT_RUNNING=$(ps -eaf | grep -v grep | grep $BOT_PID | awk '{ if ($2 == pid) { print $0 }}' pid=${BOT_PID})
		if [ -z "${BOT_RUNNING}" ]; then
			messageln "Warning: ${BOT_INSTANCE} pid ${BOT_PID} is not running, restarting it"
			$BOT_BIN --conf=$CONF_FILE --daemon
			RETVAL=$?
			exit $RETVAL
		else
			messageln "Bot is running with PID $BOT_PID"
			ps -eaf | grep -v grep | grep $BOT_PID
			lastModificationSeconds=$(date +%s -r $BOT_PID_FILE)
			currentSeconds=$(date +%s)
			((elapsedSeconds = currentSeconds - lastModificationSeconds))
			if [ $elapsedSeconds -gt 300 ]; then
				messageln "$BOT_PID_FILE last modification is more than 300 secs ago ($elapsedSeconds)"
				message -n "Killing bot PID $BOT_PID"
				kill $BOT_PID
				RETVAL=$?
				ok_failed $RETVAL
				if [ $RETVAL -eq 0 ]; then
					messageln "Restarting bot"
					$BOT_BIN --conf=$CONF_FILE --daemon
				else
					messageln "Could not kill $BOT_PID"
				fi
			fi
		fi
	else
		messageln "Warning BOT_PID is empty"
	fi
fi

exit $RETVAL