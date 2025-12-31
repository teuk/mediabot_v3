# Mediabot - https://teuk.org

  Mediabotv3 is a perl Net::Async::IRC bot now tho I started it with Net::IRC which is now deprecated
  It is still a beta version after all these years but a release is coming up

WHAT IS MEDIABOT?

  Mediabot is a Net::Async::IRC bot tested on Undernet ircu server, Libera and Epiknet (but it may supports other networks)
  The bot joins a console channel where it will notice its action
  
  Go to the Wiki section and read Installation chapter to know how to deploy it.
  
  The full documentation is in the Wiki section : https://github.com/teuk/mediabot_v3/wiki

# mediabot_v3

I've been coding this bot for a while, and it's time to write documentation (about time)

This perl bot is using Net::Async::IRC and a MySQL/MariaDB backend. I tried to make things easier to install by running the configure script but sometimes it needs manual actions. Check the Installation chapter for hints.

I hope you'll have fun using mediabot :)

TeuK

# Notes

Get the latest news on Mediabot here : [https://teuk.org/forum](https://teuk.org/forum/c/mediabot)

## Installation

### Creating a dedicated user

This is an installation example on Debian GNU/Linux 11 (bullseye)

Add a mediabot user :

```

sudo useradd -m -s /bin/bash mediabot

```

Now, give sudo rights to mediabot user and keep in mind that you MUST remove this file after the installation !
If you don't, you let an irc bot running with root privileges (trust me you don't want that).

```

echo 'mediabot ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/mediabot

```


### Required packages installation

Install needed packages :

```

sudo apt install build-essential mariadb-server default-libmysqlclient-dev default-libmysqld-dev git curl

```

### Bot installation

Now get the bot as mediabot user and run configure script :

```

sudo -iu mediabot

git clone https://github.com/teuk/mediabot_v3

cd mediabot_v3

```

The following script is supposed to do all the work for DB creation and Perl modules installation (but you may have to do manual actions sometimes) :

```

./configure

```

### Running the bot

If everything's ok then test in foreground using your config file e.g :

```

./mediabot.pl --conf=mediabot.conf

```
```

[06/08/2022 06:31:37] Reading configuration file mediabot.conf
[06/08/2022 06:31:37] mediabot.conf loaded.
[06/08/2022 06:31:37] Getting current version from VERSION file
[06/08/2022 06:31:37] -> Mediabot devel version 3.0 (20220801_111934)
[06/08/2022 06:31:37] Checking latest version from github (https://raw.githubusercontent.com/teuk/mediabot_v3/master/VERSION)
[06/08/2022 06:31:37] -> Mediabot github devel version 3.0 (20220801_111934)
[06/08/2022 06:31:37] Mediabot is up to date
[06/08/2022 06:31:37] Mediabot v3.0dev-20220801_111934 started in foreground with debug level 0
[06/08/2022 06:31:37] Logged out all users
[06/08/2022 06:31:37] Picked irc.mediabot.rules from Network Mediabot_Rules
[06/08/2022 06:31:37] Initialize Hailo
[06/08/2022 06:31:37] Connection nick : mediabot
[06/08/2022 06:31:37] Trying to connect to irc.mediabot.rules:6667 (pass : none defined)
[06/08/2022 06:31:37] *** Looking up your hostname
[06/08/2022 06:31:37] *** Checking Ident
[06/08/2022 06:31:37] *** Found your hostname
[06/08/2022 06:31:37] *** Got ident response
[06/08/2022 06:31:37] on_login() Connected to irc server irc.mediabot.rules
[06/08/2022 06:31:37] Checking timers to set at startup
[06/08/2022 06:31:37] No timer to set at startup
[06/08/2022 06:31:37] on_login() Setting user mode +i
[06/08/2022 06:31:37] Trying to join #mediabot
[06/08/2022 06:31:37] No channel to auto join
[06/08/2022 06:31:37] -irc.mediabot.rules- Highest connection count: 2 (2 clients)
[06/08/2022 06:31:37] -irc.mediabot.rules- on 1 ca 1(4) ft 10(10) tr

```

And you should see the bot join on #mediabot console channel :

```

[06:30:25] * Now talking in #mediabot

[06:31:39] * Joins: mediabot (mediabot@mediabot.mediabot.rules)

```

To run the bot in daemon mode :

```

./mediabot.pl --conf=mediabot.conf --daemon

```

Always have a look at what is going on :

```

tail -40f mediabot.log

```

DON'T FORGET TO REMOVE SUDO RIGHTS, THIS IS IMPORTANT ! :

```

sudo rm -fv /etc/sudoers.d/mediabot

```

Once you did all that, register your bot and see the commands available in Wiki section : https://github.com/teuk/mediabot_v3/wiki

