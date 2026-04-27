# mbweb — Mediabot v3 web console

`mbweb` is the Node.js / Express web console for **Mediabot v3**.

It provides a web interface for existing Mediabot users, using the Mediabot database for authentication, profile data, channel visibility, radio status, commands, quotes, metrics, and privileged views.

This console is intended to be installed next to an existing Mediabot v3 setup.

---

## Features

Current features include:

- login with an existing Mediabot user;
- user profile page;
- channel list and channel detail pages;
- visibility based on global Mediabot rights and channel-level rights;
- Icecast radio status page;
- commands and quotes browsing;
- users view for Owner/Master accounts;
- network and metrics views for privileged accounts;
- session protection with a required strong secret;
- basic HTTP hardening with Helmet.

---

## Recommended runtime layout

Repository copy:

```text
contrib/mbweb
```

Recommended live installation path:

```text
/opt/mbweb/app
```

Recommended reverse proxy path:

```text
/mediabotv3dev/
```

Local service URL:

```text
http://127.0.0.1:4002/mediabotv3dev/
```

You can change the public path by editing `MBWEB_BASE_URL` in `.env`, but the Apache reverse proxy path and the app base URL must match.

---

## Debian 13 packages

Install the required system packages:

```bash
apt update
apt install nodejs npm mariadb-client curl jq rsync apache2
```

If Apache is used as a reverse proxy, enable the proxy modules:

```bash
a2enmod proxy proxy_http headers
systemctl reload apache2
```

---

## Create the runtime directory

The service is expected to run as the existing `mediabot` user.

```bash
mkdir -p /opt/mbweb/app
chown -R mediabot:mediabot /opt/mbweb
chmod 755 /opt/mbweb
```

---

## Install the application

From the Mediabot repository:

```bash
cd /home/mediabot/mediabot_v3/contrib/mbweb

rsync -a --delete ./ /opt/mbweb/app/

chown -R mediabot:mediabot /opt/mbweb/app
find /opt/mbweb/app -type d -exec chmod 755 {} \;
find /opt/mbweb/app -type f -exec chmod 644 {} \;
```

Install Node dependencies:

```bash
cd /opt/mbweb/app
sudo -u mediabot npm install --omit=dev
```

If you are installing for development instead of production, use:

```bash
sudo -u mediabot npm install
```

---

## Configuration

Create the local `.env` file from the sample:

```bash
cd /opt/mbweb/app

cp .env.sample .env
chown mediabot:mediabot .env
chmod 600 .env
```

Edit `.env` and set the real local values.

Important variables:

```text
MBWEB_SESSION_SECRET
MBWEB_DB_HOST
MBWEB_DB_PORT
MBWEB_DB_USER
MBWEB_DB_PASS
MBWEB_DB_NAME
MBWEB_BASE_URL
```

`MBWEB_SESSION_SECRET` must be a long random value, at least 32 characters.

The application refuses to start if the session secret is missing, still set to the default value, or too short.

Never commit `.env`.

---

## Example `.env`

```ini
# mbweb runtime
NODE_ENV=production
MBWEB_HOST=127.0.0.1
MBWEB_PORT=4002
MBWEB_BASE_URL=/mediabotv3dev

# Session
# Must be a long random value, at least 32 characters.
MBWEB_SESSION_SECRET=CHANGE_ME_WITH_A_LONG_RANDOM_SECRET_32_CHARS_MIN

# MariaDB / Mediabot database
MBWEB_DB_HOST=localhost
MBWEB_DB_PORT=3306
MBWEB_DB_USER=mediabotv3
MBWEB_DB_PASS=CHANGE_ME
MBWEB_DB_NAME=mediabotv3

# Auth
MBWEB_AUTH_TABLE=USER
MBWEB_AUTH_LOGIN_COLUMNS=nickname,username
MBWEB_AUTH_PASSWORD_COLUMNS=password
MBWEB_AUTH_LEVEL_COLUMNS=id_user_level
MBWEB_ALLOW_PLAINTEXT_PASSWORDS=0

# Radio / metrics
MBWEB_RADIO_STATUS_URL=http://127.0.0.1:8000/status-json.xsl
MBWEB_RADIO_PUBLIC_BASE_URL=http://example.org:8000
MBWEB_RADIO_PRIMARY_MOUNT=/radio160.mp3
MBWEB_METRICS_URL=http://127.0.0.1:9108/metrics

# Partyline, read-only future use
MBWEB_PARTYLINE_HOST=127.0.0.1
MBWEB_PARTYLINE_PORT=23456
```

---

## Generate a strong session secret

Example:

```bash
openssl rand -hex 48
```

Then put the generated value in `.env`:

```ini
MBWEB_SESSION_SECRET=PASTE_THE_GENERATED_SECRET_HERE
```

---

## systemd service

Create `/etc/systemd/system/mbweb.service`:

```ini
[Unit]
Description=Mediabot v3 web console
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=mediabot
Group=mediabot
WorkingDirectory=/opt/mbweb/app
EnvironmentFile=/opt/mbweb/app/.env
ExecStart=/usr/bin/node /opt/mbweb/app/app.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
systemctl daemon-reload
systemctl enable --now mbweb.service
```

Check service status and logs:

```bash
systemctl status mbweb.service --no-pager -l
journalctl -u mbweb.service -n 120 --no-pager
```

Restart after code or `.env` changes:

```bash
systemctl restart mbweb.service
```

---

## Apache reverse proxy example

Example Apache snippet:

```apache
ProxyPass        /mediabotv3dev/ http://127.0.0.1:4002/mediabotv3dev/
ProxyPassReverse /mediabotv3dev/ http://127.0.0.1:4002/mediabotv3dev/
```

Then reload Apache:

```bash
apachectl configtest
systemctl reload apache2
```

If you use a different public path, update both:

```text
Apache ProxyPass path
MBWEB_BASE_URL
```

They must stay consistent.

---

## Health checks

Local checks:

```bash
curl -s http://127.0.0.1:4002/mediabotv3dev/health | jq .
curl -I http://127.0.0.1:4002/mediabotv3dev/login
```

Browser check:

```text
https://example.org/mediabotv3dev/
```

Login with an existing Mediabot user.

---

## Development checks

From the live application directory:

```bash
cd /opt/mbweb/app

node -c app.js
find lib -maxdepth 1 -name '*.js' -print -exec node -c {} \;
find routes -maxdepth 1 -name '*.js' -print -exec node -c {} \;
```

Check current dependencies:

```bash
npm ls --depth=0
```

---

## Repository safety rules

Files that must never be committed:

```text
.env
.env.*
node_modules/
*.log
*.bak*
*.zip
*.tar.gz
```

The only allowed environment file in the repository is:

```text
.env.sample
```

Before committing, check:

```bash
cd /home/mediabot/mediabot_v3

find contrib/mbweb \
  \( -name '.env' -o \( -name '.env.*' ! -name '.env.sample' \) -o -name 'node_modules' -o -name '*.bak*' -o -name '*.log' -o -name '*.zip' -o -name '*.tar.gz' \) \
  -print
```

The command above should print nothing.

You can also review possible secret-looking strings:

```bash
grep -RInE 'MBWEB_DB_PASS=|MBWEB_SESSION_SECRET=|password|secret|passwd' contrib/mbweb \
  --exclude='.env.sample' \
  --exclude='README.md' \
  --exclude='package-lock.json' \
  --exclude='package.json' || true
```

Most results should be normal code references, not real secrets.

---

## Notes

`mbweb` is currently provided as a contributed web console for Mediabot v3.

The live app can evolve under `/opt/mbweb/app`; when ready, copy the cleaned source back into `contrib/mbweb`, excluding local runtime files and secrets.

Do not publish local synchronization scripts unless they are generic and safe for other users.

