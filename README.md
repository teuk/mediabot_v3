# Mediabot v3

Mediabot v3 is a multi-purpose IRC bot written in Perl.

It is designed for real-world IRC operations and long-term use, with support for channel administration, user and hostmask management, database-backed commands, runtime administration, utility features, analytics, media helpers, URL title handling, radio-oriented helpers, web/API endpoints, observability tooling, and a dedicated TCP admin interface called **Partyline**.

This README gives both:

- a clear overview of the project;
- a practical Debian 13 quick install path for people who want to get a clean test instance running without guessing every Linux step.

---

## Table of contents

- [Release status](#release-status)
- [Which version should I use?](#which-version-should-i-use)
- [Key features](#key-features)
- [Debian 13 quick install](#debian-13-quick-install)
- [Installation paths](#installation-paths)
- [Temporary sudo during installation](#temporary-sudo-during-installation)
- [Create the dedicated user](#create-the-dedicated-user)
- [Install required Debian packages](#install-required-debian-packages)
- [Run configure](#run-configure)
- [Database setup](#database-setup)
- [Configuration](#configuration)
- [First checks and first start](#first-checks-and-first-start)
- [Remove temporary sudo access](#remove-temporary-sudo-access)
- [Optional systemd service](#optional-systemd-service)
- [Optional radio stack on Debian 13](#optional-radio-stack-on-debian-13)
- [Mediabot local API checks](#mediabot-local-api-checks)
- [Important runtime notes](#important-runtime-notes)
- [Main entry points](#main-entry-points)
- [Recommended post-install validation](#recommended-post-install-validation)
- [Documentation](#documentation)
- [Partyline](#partyline)
- [Verify downloads](#verify-downloads)
- [Project links](#project-links)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Release status

- **Stable release:** `3.1`
- **Current development line:** `3.2-dev`

Mediabot follows a simple versioning rule:

- **odd minor versions** = **stable releases**
- **even minor versions** = **development / beta lines**

Examples:

- `3.1` = stable release
- `3.2-dev` = development line
- `3.3` = next stable release

This makes it immediately clear whether a version is intended for deployment, testing, or active development.

---

## Which version should I use?

### Stable release (`3.1`)

Choose the stable release if you want:

- the recommended version for deployment;
- the documented installation path;
- a release tarball-based install;
- a cleaner, validated baseline.

This is the right choice for most users.

### Development version (`3.2-dev`)

Choose the development version if you want:

- the latest work in progress;
- Git-based development access;
- changes that may not yet be fully documented or finalized;
- the current development branch after the 3.1 release.

This is the right choice for contributors and testers.

---

## Key features

Depending on configuration and enabled features, Mediabot can provide:

- IRC channel administration and moderation;
- bot user and hostmask management;
- managed channel registration and channel settings;
- database-backed public commands;
- analytics and activity/statistics helpers;
- URL title handling;
- YouTube / TMDB / media helpers;
- timers and runtime administration;
- Partyline TCP admin interface;
- utility and conversational commands;
- radio-oriented helpers where configured;
- local API endpoints for future web interface integration;
- observability-friendly outputs for external tools such as Grafana.

---

## Debian 13 quick install

This section is intentionally explicit. It is meant to help someone install a clean Mediabot test instance on Debian 13 without guessing every Linux step.

The examples assume this project directory:

```text
/home/mediabot/mediabot_v3
```

The normal installation flow is:

1. install the minimal Debian packages needed to bootstrap the system;
2. create the dedicated `mediabot` user;
3. give that user **temporary sudo access** for setup;
4. download Mediabot;
5. run `./configure`;
6. configure the bot;
7. test the bot in foreground;
8. **remove the temporary sudo access before real IRC use**.

### 1. Bootstrap the system

Run this first part as `root`:

```bash
apt update
apt install -y \
  sudo \
  git \
  curl \
  wget \
  jq \
  unzip \
  zip \
  build-essential \
  make \
  gcc \
  pkg-config \
  mariadb-server \
  mariadb-client

systemctl enable --now mariadb
```

### 2. Create the Mediabot user

```bash
adduser mediabot
```

### 3. Give temporary sudo access for installation

`./configure` may need administrative rights, especially when installing Perl dependencies through CPAN or preparing system-level paths.

Create a temporary sudoers file:

```bash
echo 'mediabot ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/mediabot
sudo chmod 440 /etc/sudoers.d/mediabot
sudo visudo -cf /etc/sudoers.d/mediabot
```

This is intentionally temporary.

Do **not** keep an IRC bot user with permanent passwordless sudo access.

### 4. Switch to the Mediabot user

```bash
su - mediabot
```

Check:

```bash
whoami
groups
pwd
sudo -n true && echo "temporary sudo OK"
```

Expected result:

```text
mediabot
mediabot
/home/mediabot
temporary sudo OK
```

The `groups` output may also contain `sudo` depending on how the local system was prepared, but the important check during install is that `sudo -n true` works.

### 5. Download Mediabot

For the stable release:

```bash
cd /home/mediabot
wget https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.gz
tar xzf mediabot_v3-3.1.tar.gz
cd mediabot_v3-3.1
```

For the development tree:

```bash
cd /home/mediabot
git clone https://github.com/teuk/mediabot_v3.git
cd mediabot_v3
```

### 6. Run configure

This is the important step.

Run the project installer/configuration helper before trying to start the bot:

```bash
./configure
```

If `./configure` installs CPAN modules or system-level components, the temporary sudo rule above allows it to complete cleanly without forcing the user to become `root` for the whole install.

After `./configure`, continue with the configuration file and startup checks below.

### 7. Prepare the local configuration

```bash
cp conf/mediabot.sample.conf conf/mediabot.conf
chmod 600 conf/mediabot.conf
vi conf/mediabot.conf
```

At minimum, configure:

- database access;
- IRC server;
- bot nickname;
- channels;
- admin/owner information;
- optional radio settings.

### 8. Check syntax and start in foreground

```bash
perl -c mediabot.pl
```

Expected result:

```text
mediabot.pl syntax OK
```

Then start manually first:

```bash
./start
```

If you prefer to see the raw Perl entry point directly during debugging:

```bash
perl --conf=mediabot.conf mediabot.pl
```

Do not create a systemd service until the foreground start works correctly.

### 9. Remove temporary sudo access

After installation and tests, remove the temporary sudoers file:

```bash
sudo rm -f /etc/sudoers.d/mediabot
sudo -k
```

Verify from a fresh shell as `mediabot`:

```bash
sudo -n true && echo "ERROR: sudo still active" || echo "OK: no passwordless sudo"
```

Expected result:

```text
OK: no passwordless sudo
```

This step is not optional for a real IRC deployment.

A bot connected to IRC must not keep passwordless root privileges.

---

## Installation paths

Mediabot can be installed from a stable release archive or from the development Git tree.

### Stable release install

Use the release tarball for the stable version.

#### `.tar.gz`

```bash
wget https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.gz
tar xzf mediabot_v3-3.1.tar.gz
cd mediabot_v3-3.1
./configure
```

#### `.tar.xz`

```bash
wget https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.xz
tar xJf mediabot_v3-3.1.tar.xz
cd mediabot_v3-3.1
./configure
```

### Development install (`3.2-dev`)

Use Git for the development version.

```bash
cd /home/mediabot
git clone https://github.com/teuk/mediabot_v3.git
cd mediabot_v3
./configure
```

---

## Temporary sudo during installation

The `mediabot` user is a runtime user, not an administrator.

However, during initial installation, `./configure` may need elevated privileges for tasks such as:

- installing missing Perl modules through CPAN;
- preparing system paths;
- installing or validating helper commands;
- writing files that require root privileges.

For that reason, the recommended approach is:

1. give `mediabot` temporary passwordless sudo access;
2. run `./configure` and installation tests;
3. remove sudo access before normal IRC use.

Create the temporary rule:

```bash
echo 'mediabot ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/mediabot
sudo chmod 440 /etc/sudoers.d/mediabot
sudo visudo -cf /etc/sudoers.d/mediabot
```

Remove it after successful installation:

```bash
sudo rm -f /etc/sudoers.d/mediabot
sudo -k
```

Verify that passwordless sudo is gone:

```bash
sudo -n true && echo "ERROR: sudo still active" || echo "OK: no passwordless sudo"
```

---

## Create the dedicated user

Mediabot should not run as `root`.

Create a dedicated user:

```bash
adduser mediabot
```

Switch to this user:

```bash
su - mediabot
```

Check the current user and home directory:

```bash
whoami
pwd
```

Expected result:

```text
mediabot
/home/mediabot
```

Administrative rights should only be granted temporarily during installation, as described above.

---

## Install required Debian packages

### Minimal bootstrap packages

`./configure` is the main project entry point, but a fresh Debian system still needs a small bootstrap set first.

```bash
apt update
apt install -y \
  sudo \
  git \
  curl \
  wget \
  jq \
  unzip \
  zip \
  build-essential \
  make \
  gcc \
  pkg-config \
  mariadb-server \
  mariadb-client
```

### Common Perl packages available from Debian

Some dependencies may be installed by Debian packages, while others may be handled by `./configure` and CPAN.

```bash
apt install -y \
  libdbi-perl \
  libdbd-mysql-perl \
  libjson-perl \
  libjson-xs-perl \
  libwww-perl \
  liburi-perl \
  libhtml-parser-perl \
  libhtml-tree-perl \
  libxml-libxml-perl \
  libtry-tiny-perl \
  libdatetime-perl \
  libdatetime-format-strptime-perl \
  libnet-ssleay-perl \
  libio-socket-ssl-perl \
  libmime-base64-perl \
  libencode-perl \
  libdigest-sha-perl \
  libfile-slurp-perl \
  libfile-tail-perl \
  libterm-readkey-perl
```

### Useful administration tools

```bash
apt install -y \
  screen \
  tmux \
  htop \
  lsof \
  net-tools \
  iproute2 \
  dnsutils \
  rsync
```

### Optional Chromium support

Mediabot may use Chromium for modern URL title handling when static HTTP fetching is not enough.

```bash
apt install -y chromium
```

### Optional radio stack packages

```bash
apt install -y icecast2 liquidsoap
```

### Optional web/API development packages

```bash
apt install -y nodejs npm
```

### Version checks

```bash
perl -v
node -v
npm -v
mysql --version
icecast2 -v
liquidsoap --version
```

Some commands may fail if the corresponding optional package was not installed.

---

## Run configure

`./configure` is the normal setup entry point.

Run it from the project directory as the `mediabot` user:

```bash
cd /home/mediabot/mediabot_v3
./configure
```

For a stable release tarball, adjust the directory name:

```bash
cd /home/mediabot/mediabot_v3-3.1
./configure
```

Do not skip this step.

It is responsible for preparing the project installation and may install or validate required Perl dependencies.

If `./configure` needs root privileges for CPAN or system operations, use the temporary sudo setup described in this README. Do not run the bot itself as `root`.

---

## Database setup

Start and enable MariaDB:

```bash
systemctl enable --now mariadb
systemctl status mariadb --no-pager -l
```

Create the database and user:

```bash
mysql -u root -p
```

Example SQL:

```sql
CREATE DATABASE mediabot CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER 'mediabot'@'localhost' IDENTIFIED BY 'change-this-password';

GRANT ALL PRIVILEGES ON mediabot.* TO 'mediabot'@'localhost';

FLUSH PRIVILEGES;
EXIT;
```

Test access:

```bash
mysql -u mediabot -p mediabot
```

---

## Configuration

Copy the sample configuration:

```bash
cp conf/mediabot.sample.conf conf/mediabot.conf
chmod 600 conf/mediabot.conf
```

Edit it:

```bash
vi conf/mediabot.conf
```

At minimum, check the database, IRC, and optional radio settings.

Example database and IRC baseline:

```ini
[database]
DB_HOST=localhost
DB_NAME=mediabot
DB_USER=mediabot
DB_PASS=change-this-password

[irc]
SERVER=irc.example.net
PORT=6667
NICK=mediabot
USERNAME=mediabot
REALNAME=Mediabot v3
```

Example radio baseline for the Icecast JSON status flow:

```ini
[radio]
RADIO_PUB=900
RADIO_PORT=8000
RADIO_SOURCE=0
YOUTUBEDL_INCOMING=/home/mediabot/mediabot_v3/mp3
LIQUIDSOAP_PLAYLIST=plglob(dot)m3u
RADIO_ADMINPASS=change-this-password
LIQUIDSOAP_TELNET_PORT=1234
RADIO_HOSTNAME=myradio.com
YTDLP_PATH=/usr/local/bin/yt-dlp
LIQUIDSOAP_TELNET_HOST=localhost
RADIO_URL=radio.mp3
RADIO_JSON=status-json.xsl

RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000
RADIO_ICECAST_PUBLIC_BASE_URL=http://teuk.org:8000
RADIO_ICECAST_TIMEOUT=5
RADIO_ICECAST_PRIMARY_MOUNT=/radio160.mp3
```

Never commit the real `mediabot.conf` file with passwords.

---

## First checks and first start

### Check Perl syntax

```bash
perl -c mediabot.pl
```

Expected result:

```text
mediabot.pl syntax OK
```

Check all Perl modules in the `Mediabot/` directory:

```bash
find Mediabot -name '*.pm' -print -exec perl -c {} \;
```

### Start in foreground

For the first launch, do not use systemd yet.

Start Mediabot in foreground with the explicit configuration file:

```bash
cd /home/mediabot/mediabot_v3
perl mediabot.pl --conf=mediabot.conf
```

This makes startup errors visible directly in the terminal.

Stop the foreground process with:

```text
CTRL+C
```

### Start in daemon mode

Once the foreground start works, start Mediabot as a daemon with:

```bash
cd /home/mediabot/mediabot_v3
perl mediabot.pl --conf=mediabot.conf --daemon
```

Then check the log from another terminal:

```bash
tail -f logs/mediabot.log
```

If your log file name differs, list the available logs first:

```bash
ls -lh logs/
```

### Register the owner from IRC, then check Partyline

On a fresh setup, the first owner registration is done from IRC, not from Partyline.

From your IRC client, once the bot is connected, send a private message to the bot:

```text
/msg mediabot register <owner> <password>
```

Replace `mediabot` with the actual bot nickname if you changed it in `mediabot.conf`.

Only after this IRC registration step can you connect to Partyline locally from another terminal:

```bash
telnet localhost 23456
```

Then authenticate with the registered owner credentials if prompted by your Partyline configuration.

During deployment, enable a console level to see what is going on:

```text
.console 2
```

or, for more detail:

```text
.console 3
```

This is useful during deployment because it lets you see runtime problems directly from the bot administration interface.

---

## Remove temporary sudo access

After `./configure`, dependency installation, database preparation, and foreground tests are complete, remove the temporary sudoers rule:

```bash
sudo rm -f /etc/sudoers.d/mediabot
sudo -k
```

Then verify from a new `mediabot` shell:

```bash
sudo -n true && echo "ERROR: sudo still active" || echo "OK: no passwordless sudo"
```

Expected result:

```text
OK: no passwordless sudo
```

This is a hard security rule.

Mediabot is an IRC bot. It should not remain connected to IRC with passwordless sudo access to the host.

---

## Optional systemd service

Create a systemd service only after the foreground start works and after temporary sudo access has been removed.

Create:

```bash
sudo vi /etc/systemd/system/mediabot.service
```

Example unit:

```ini
[Unit]
Description=Mediabot v3 IRC bot
After=network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service

[Service]
Type=simple
User=mediabot
Group=mediabot
WorkingDirectory=/home/mediabot/mediabot_v3
ExecStart=/usr/bin/perl /home/mediabot/mediabot_v3/mediabot.pl --conf=/home/mediabot/mediabot_v3/mediabot.conf --daemon
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Enable and start it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mediabot.service
```

Check status and logs:

```bash
systemctl status mediabot.service --no-pager -l
journalctl -u mediabot.service -f
```

---

## Optional radio stack on Debian 13

Mediabot can read Icecast status information through JSON and expose that state locally for future web/UI integration.

For a clean test environment, keep the test radio stack separate from any production stream.

Recommended test layout:

```text
Icecast2 test instance:
  port: 8000
  config: /etc/icecast2/icecast-8000.xml
  logs: /var/log/icecast2-8000/
  runtime: /run/icecast2-8000/

Liquidsoap test instance:
  config: /etc/liquidsoap/radio-8000.liq
  log: /var/log/liquidsoap/liquidsoap-8000.log
  telnet: 127.0.0.1:1235
  harbor/live input: 18005
```

Install the packages:

```bash
sudo apt update
sudo apt install -y icecast2 liquidsoap curl jq
```

Useful sample files to keep in the repository:

```text
contrib/icecast2/icecast-8000.sample.xml
contrib/liquidsoap/radio-8000.sample.liq
conf/mediabot.sample.conf
```

The sample files should document the expected service layout without exposing real passwords.

### Radio sanity checks

Check Icecast JSON:

```bash
curl -s http://127.0.0.1:8000/status-json.xsl | jq .
```

Check expected mounts:

```bash
curl -s http://127.0.0.1:8000/status-json.xsl \
  | jq '.icestats.source'
```

Check Liquidsoap logs:

```bash
tail -n 100 /var/log/liquidsoap/liquidsoap-8000.log
```

Check listening ports:

```bash
ss -lntp | egrep ':8000\b|:1235\b|:18005\b'
```

Expected test mounts may include:

```text
/radio64.mp3
/radio160.mp3
/radio320.mp3
```

---

## Mediabot local API checks

If the local API is enabled, check the radio endpoint:

```bash
curl -s http://127.0.0.1:9108/api/radio/status | jq .
```

The exact fields may evolve, but the endpoint should return valid JSON.

A healthy response should clearly indicate that the radio status path is working and that Mediabot can read the configured Icecast source.

---

## Important runtime notes

### Chromium

Mediabot may use **Chromium** at runtime for some modern URL-title handling cases where a simple static HTTP fetch is not enough.

If you want full expected 3.1 URL-title behavior, install Chromium:

```bash
sudo apt update
sudo apt install -y chromium
```

### Hailo

The dependency path for **Hailo** may require a fallback install path during setup.

This is handled by the project install scripts, but it is worth knowing if you are validating a fresh system or reviewing dependency logs.

---

## Main entry points

After installation:

### Configure

```bash
./configure
```

### Start in foreground

```bash
perl mediabot.pl --conf=mediabot.conf
```

### Start in daemon mode

```bash
perl mediabot.pl --conf=mediabot.conf --daemon
```

### Check logs

```bash
tail -f logs/mediabot.log
```

### Register owner, then connect to Partyline

The initial owner registration is done from IRC with a private message to the bot:

```text
/msg mediabot register <owner> <password>
```

Replace `mediabot` with the actual bot nickname if needed.

After that registration, connect to Partyline from another terminal:

```bash
telnet localhost 23456
```

During deployment, use a console level to watch what happens:

```text
.console 2
```

or:

```text
.console 3
```

For a first install, prefer a foreground/manual start first so errors are visible.

---

## Recommended post-install validation

After installation, at minimum verify:

- `./configure` completed successfully;
- the bot parses cleanly;
- required Perl modules are visible;
- DB connection works;
- startup works;
- expected channels join;
- auth path works;
- rehash works;
- restart works;
- Partyline works if enabled;
- optional Icecast JSON status works if radio support is configured;
- optional local API endpoint works if API support is enabled;
- passwordless sudo has been removed from the `mediabot` user.

Useful commands:

```bash
perl -c mediabot.pl
find Mediabot -name '*.pm' -print -exec perl -c {} \;
mysql -u mediabot -p mediabot
ps aux | grep '[m]ediabot'
tail -n 100 logs/*.log
sudo -n true && echo "ERROR: sudo still active" || echo "OK: no passwordless sudo"
```

If using systemd:

```bash
systemctl status mediabot.service --no-pager -l
journalctl -u mediabot.service -f
sudo systemctl restart mediabot.service
```

The project also includes a live testing path for deeper validation.

See the wiki page:

- [Testing](https://github.com/teuk/mediabot_v3/wiki/Testing)

---

## Documentation

The GitHub wiki is the main documentation hub.

Recommended reading order:

1. Installation
2. Configuration
3. Public commands
4. Private and admin commands
5. Partyline
6. Troubleshooting
7. Testing
8. Release and upgrade notes

Wiki:

- [Mediabot Wiki](https://github.com/teuk/mediabot_v3/wiki)

Direct wiki pages:

- [Installation](https://github.com/teuk/mediabot_v3/wiki/Installation)
- [Configuration](https://github.com/teuk/mediabot_v3/wiki/Configuration)
- [Public commands](https://github.com/teuk/mediabot_v3/wiki/Public-commands)
- [Private and admin commands](https://github.com/teuk/mediabot_v3/wiki/Private-and-admin-commands)
- [Partyline](https://github.com/teuk/mediabot_v3/wiki/Partyline)
- [Troubleshooting](https://github.com/teuk/mediabot_v3/wiki/Troubleshooting)
- [Testing](https://github.com/teuk/mediabot_v3/wiki/Testing)
- [Release and upgrade notes](https://github.com/teuk/mediabot_v3/wiki/Release-and-upgrade-notes)

---

## Partyline

Mediabot includes a dedicated TCP admin interface called **Partyline**.

It allows authenticated operators to:

- inspect bot state;
- send messages;
- join or part channels;
- reload runtime state;
- restart the bot;
- terminate the bot.

This interface is documented separately in the wiki and should be treated as an administrative surface.

On a fresh install, remember that the first owner registration happens from IRC with `/msg mediabot register <owner> <password>`. Partyline access comes after that registration step, not before.

See:

- [Partyline documentation](https://github.com/teuk/mediabot_v3/wiki/Partyline)

---

## Fresh install and release philosophy

The goal of the 3.1 cycle was not only to keep adding features, but to make the project:

- installable on a fresh system;
- more predictable at runtime;
- easier to test;
- easier to document;
- easier to release cleanly.

That is why 3.1 matters.

It is not just another snapshot: it is a proper stable release target.

A stable release should be:

- downloadable;
- documented;
- testable;
- understandable without guessing.

A development tree should be:

- the place where active work continues;
- clearly identified as development;
- used by contributors and testers.

This is why Mediabot distinguishes clearly between a **stable tarball** and a **development Git tree**.

---

## Verify downloads

You can verify the release archives with the published SHA256 checksums.

Download checksum file:

```bash
wget https://teuk.org/downloads/mediabot/SHA256SUMS
```

Verify the downloaded archive:

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

If you downloaded only one archive, `--ignore-missing` avoids errors for files that are not present locally.

---

## Project links

- [Repository](https://github.com/teuk/mediabot_v3)
- [Wiki](https://github.com/teuk/mediabot_v3/wiki)
- Stable downloads:
  - [mediabot_v3-3.1.tar.gz](https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.gz)
  - [mediabot_v3-3.1.tar.xz](https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.xz)
  - [SHA256SUMS](https://teuk.org/downloads/mediabot/SHA256SUMS)

---

## Security notes

Do not commit:

- real passwords;
- real IRC operator credentials;
- real database passwords;
- real Icecast admin passwords;
- private local paths;
- production-only configuration files;
- local runtime files;
- generated logs.

Use sample files instead:

```text
conf/mediabot.sample.conf
contrib/icecast2/icecast-8000.sample.xml
contrib/liquidsoap/radio-8000.sample.liq
```

Real local files should stay ignored by Git.

Before committing, check:

```bash
git status
git diff --cached
```

---

### Runtime privilege rule

The `mediabot` user may temporarily receive passwordless sudo during installation.

That access must be removed before running the bot as a normal IRC service:

```bash
sudo rm -f /etc/sudoers.d/mediabot
sudo -k
```

A bot connected to IRC must not have passwordless root access.

---

## Troubleshooting

### Check the current directory

```bash
pwd
ls -la
```

### Check whether configure was run

```bash
ls -la ./configure
./configure
```

### Check whether the bot process is running

```bash
ps aux | grep '[m]ediabot'
```

### Check recent logs

```bash
tail -n 100 logs/*.log
```

### Check MariaDB

```bash
systemctl status mariadb --no-pager -l
mysql -u mediabot -p mediabot
```

### Check Perl syntax again

```bash
perl -c mediabot.pl
find Mediabot -name '*.pm' -print -exec perl -c {} \;
```

### Check radio status

```bash
curl -s http://127.0.0.1:8000/status-json.xsl | jq .
```

### Check local API status

```bash
curl -s http://127.0.0.1:9108/api/radio/status | jq .
```

### Check systemd service logs

```bash
systemctl status mediabot.service --no-pager -l
journalctl -u mediabot.service -n 100 --no-pager
journalctl -u mediabot.service -f
```

---

### Check that passwordless sudo was removed

```bash
sudo -n true && echo "ERROR: sudo still active" || echo "OK: no passwordless sudo"
```

---

## License

See:

- [LICENSE.md](LICENSE.md)

---

## Next step

If you are here to install Mediabot for real use, start with the stable release tarball, run `./configure`, then read the wiki:

- [Mediabot Wiki](https://github.com/teuk/mediabot_v3/wiki)

If you are here to contribute or test the current development line, use the Git tree and treat `3.2-dev` as active development.
