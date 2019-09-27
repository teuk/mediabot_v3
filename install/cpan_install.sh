#!/bin/bash

if [ $(id -u) -ne 0 ]; then
	echo "This script must be run as root user"
	exit 1
fi

SCRIPT_LOGFILE=cpan_install.log
CPAN_LOGFILE=cpan_install_details.log

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

function wait_for_cmd {
	$1 >>${CPAN_LOGFILE} 2>&1 &
	WAIT_PID=$!
	while [ -d /proc/$WAIT_PID ];
	 do
	  echo -n "."
	  sleep 5
	 done
	echo -n " "
	wait $WAIT_PID
}

message "Autoconfigure cpan"
bash -c "(echo y;echo o conf prerequisites_policy follow;echo o conf commit)|cpan" >>$CPAN_LOGFILE 2>&1
ok_failed $?

messageln "Install perl module Module::Build"
echo "Module::Build" | while read perl_module
 do
  message "Checking $perl_module "
  perl -M$perl_module -e "exit 0;" &>/dev/null
  if [ $? -ne 0 ]; then
  	echo -n "Not found. Installing via cpan "
		wait_for_cmd "./install_perl_module.sh $perl_module"
		ok_failed $?
	else
		echo "OK"
	fi
 done

messageln "Install perl modules"
echo "Getopt::Long
File::Basename
IO::Async::Loop
IO::Async::Timer::Periodic
Net::Async::IRC
Data::Dumper
Config::Simple
Date::Format
Data::Dumper
Date::Parse
DBI
DBD::mysql
Switch
Memory::Usage
String::IRC
JSON
DateTime
DateTime::TimeZone" | while read perl_module
 do
  message "Checking $perl_module "
  perl -M$perl_module -e "exit 0;" &>/dev/null
  if [ $? -ne 0 ]; then
  	echo -n "Not found. Installing via cpan "
		wait_for_cmd "./install_perl_module.sh $perl_module"
		ok_failed $?
	else
		echo "OK"
	fi
 done

messageln "Verify perl modules installation"
echo "Getopt::Long
File::Basename
IO::Async::Loop
IO::Async::Timer::Periodic
Net::Async::IRC
Data::Dumper
Config::Simple
Date::Format
Data::Dumper
Date::Parse
DBI
DBD::mysql
Switch
Memory::Usage
String::IRC
JSON
DateTime
DateTime::TimeZone" | while read perl_module
 do
  message "Checking $perl_module"
  perl -M$perl_module -e "exit 0;"
	ok_failed $?
 done
 
messageln "Perl modules successfully installed"