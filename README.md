# mediabot_v3

  Mediabotv3 is a perl Net::Async::IRC bot
  It is still a beta version and has been tested on Undernet ircu server and Freenode.

WHAT IS MEDIABOT?

  Mediabot is a Net::Async::IRC bot tested on Undernet ircu server and Freenode (but it may supports other networks)
  The bot joins a console channel where it will notice its action
  
  Go to the Wiki section and read Installation chapter to know how to deploy it.
  
  Read COMMANDS file to know how to register it at first use and refer to bot log file to know what is going on.


# Mediabot

I've been coding this bot for a while, and it's time to write documentation (about time)

This perl bot is using Net::Async::IRC and a MySQL/MariaDB backend. I tried to make things easier to install by running the configure script but sometimes it needs manual actions. Check the Installation chapter for hints.

I hope you'll have fun using mediabot :)

TeuK


## Installation

### Creating a dedicated user

This is an installation example on Debian GNU/Linux 11 (bullseye)

Add a mediabot user :

$ sudo useradd -m -s /bin/bash mediabot


Now, give sudo rights to mediabot user and keep in mind that you MUST remove this file after the installation !
If you don't, you let an irc bot running with root privileges (trust me you don't want that).

$ sudo echo 'mediabot ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/mediabot


### Required packages installation

Install needed packages :

$ sudo apt install build-essential mariadb-server default-libmysqlclient-dev default-libmysqld-dev git curl


### Bot installation

Now get the bot as mediabot user and run configure script :

$ sudo -iu mediabot

(mediabot)$ git clone https://github.com/teuk/mediabot_v3

(mediabot)$ cd mediabot_v3

The following script is supposed to do all the work for DB creation and Perl modules installation (but you may have to do manual actions sometimes) :

(mediabot)$ ./configure


### Running the bot

If everything's ok then test in foreground using your config file e.g :


(mediabot)$ ./mediabot.pl --conf=mediabot.conf


To run the bot in daemon mode :


(mediabot)$ ./mediabot.pl --conf=mediabot.conf --daemon

Always have a look at what is going on :

(mediabot)$ tail -40f mediabot.log


DON'T FORGET TO REMOVE SUDO RIGHTS, THIS IS IMPORTANT ! :

$ sudo rm -fv /etc/sudoers.d/mediabot

