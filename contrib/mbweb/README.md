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
- persistent MariaDB sessions in production with explicit expiry and cleanup;
- centralized session-bound CSRF protection for every unsafe HTTP method;
- bounded login throttling and redacted security logs;
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
sudo a2enmod proxy proxy_http headers
sudo systemctl reload apache2.service
```

---

## Canonical deployment

The supported deployment path is transactional and must run as root. It keeps
the private `.env` already installed in `/opt/mbweb/app`, stages the canonical
source, installs the exact production dependency tree from `package-lock.json`,
records the dependency audit and creates a private rollback point before it
touches the running application.

The clean candidate is root-owned with directories traversable and files
readable by the service identity; the private `.env` remains mode `0600` and
owned by `mediabot`. Before stopping the live service, the deployer resolves
and loads every declared production dependency from the staged application as
`mediabot`. It repeats the same proof against the installed runtime.

```bash
sudo install/mbweb_deploy.sh deploy \
  --source /home/mediabot/mediabot_v3/contrib/mbweb \
  --unit /home/mediabot/mediabot_v3/install/systemd/mbweb.service \
  --health-url http://127.0.0.1:4002/mediabotv3dev/health
```

The command prints `MBWEB_BACKUP`, `MBWEB_AUDIT` and the installed lockfile
digest. Keep the backup path for the matching rollback:

```bash
sudo install/mbweb_deploy.sh rollback \
  --backup /var/lib/mbweb-deploy/backups/mbweb-YYYYMMDD_HHMMSS.XXXXXX \
  --health-url http://127.0.0.1:4002/mediabotv3dev/health
```

Read-only verification neither installs dependencies nor restarts the service:

```bash
sudo install/mbweb_deploy.sh verify \
  --source /home/mediabot/mediabot_v3/contrib/mbweb \
  --unit /home/mediabot/mediabot_v3/install/systemd/mbweb.service \
  --health-url http://127.0.0.1:4002/mediabotv3dev/health
```

The deployer excludes private or generated paths, serializes concurrent runs,
and automatically restores its backup if activation or health verification
fails. A failed activation records bounded service status and journal evidence.
Its canonical-runtime comparison uses checksums for file content while ignoring
the intentional permission and ownership difference between repository source
and the root-owned runtime. Backup-to-runtime and backup-to-backup comparisons
remain metadata-exact. It only controls `mbweb.service`.

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
MBWEB_SESSION_STORE
MBWEB_SESSION_TABLE
MBWEB_SESSION_MAX_AGE_MS
MBWEB_SESSION_CLEANUP_INTERVAL_MS
MBWEB_DB_HOST
MBWEB_DB_PORT
MBWEB_DB_USER
MBWEB_DB_PASS
MBWEB_DB_NAME
MBWEB_BASE_URL
```

`MBWEB_SESSION_SECRET` must be a long random value, at least 32 characters.

The application refuses to start if the session secret is missing, still set
to the default value, or too short. Production also refuses the default
in-memory session store and any non-loopback bind address.

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
MBWEB_SESSION_STORE=mysql
MBWEB_SESSION_TABLE=MBWEB_SESSION
MBWEB_SESSION_MAX_AGE_MS=28800000
MBWEB_SESSION_CLEANUP_INTERVAL_MS=300000

# MariaDB / Mediabot database
MBWEB_DB_HOST=localhost
MBWEB_DB_PORT=3306
MBWEB_DB_USER=mbweb
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

## Persistent session table and least privilege

Production sessions use the dedicated `MBWEB_SESSION` table. Existing
databases receive it from:

```text
install/migrations/20260904_mbweb_sessions.sql
```

The migration creates only the table. It does not create an account or grant
rights. Use a dedicated local mbweb identity. It needs read-only access to the
tables exposed by the console, and SELECT, INSERT, UPDATE and DELETE only on
`MBWEB_SESSION`. It does not need `CREATE`, `ALTER`, `DROP`, `INDEX`,
`TRIGGER`, `FILE`, `PROCESS`, `SUPER`, `GRANT OPTION` or access to MariaDB
privilege tables.

An administrator may adapt this explicit grant skeleton to the selected
database and account:

```sql
GRANT SELECT ON mediabotv3.`USER` TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.USER_LEVEL TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.USER_CHANNEL TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.USER_HOSTMASK TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.CHANNEL TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.CHANNEL_BAN TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.CHANSET_LIST TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.CHANNEL_SET TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.NETWORK TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.SERVERS TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.PUBLIC_COMMANDS TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.PUBLIC_COMMANDS_CATEGORY TO 'mbweb'@'localhost';
GRANT SELECT ON mediabotv3.QUOTES TO 'mbweb'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON mediabotv3.MBWEB_SESSION TO 'mbweb'@'localhost';
```

The store checks table readiness before opening the HTTP listener. A failed
readiness check or listener start closes the session and database resources.
A transient
connection loss is retried once through the pool; a repeated or non-transient
failure is returned to the session middleware. There is no in-memory fallback.
Expired rows are indexed and pruned in batches of at most 1000 every five
minutes by default. The cleanup timer is unreferenced and shutdown stops it
before closing the shared pool. Stored expiry is capped by the configured
server-side lifetime even if an application cookie contains a later date.

---

## Request-security boundary

Every `POST`, `PUT`, `PATCH` and `DELETE` request crosses one central
session-bound CSRF check. HTML forms carry `_csrf`; JSON clients use
`X-CSRF-Token`. Supplying conflicting header and form tokens fails closed.
Login rotates the complete session and its CSRF token before saving the
authenticated user. Form and JSON bodies are capped at 32 KiB, and forms at
64 parameters. Logout is a protected POST and clears the scoped cookie.

The only local maintenance mutation is cache clearing. It remains Owner-only,
uses POST, crosses the same CSRF check, synchronously refreshes authorization
and emits a bounded audit event. It returns an unavailable response instead of
trusting stale privileges when that refresh fails. GET navigation never clears
or force-refreshes shared caches.

Login throttling keeps at most 2048 source entries, prunes expired windows and
rejects unseen sources while full. Logs retain fixed event names and bounded
error codes, never passwords, session secrets, cookies, query contents or
private upstream payloads.

---

## systemd service

Install the canonical unit from `install/systemd/mbweb.service`. It retains the
accepted `mediabot` identity but makes the application tree read-only, gives
the process only a private temporary directory and applies restart-rate,
namespace, kernel and privilege restrictions. There is no persistent writable
filesystem path.

The complete unit is maintained in the repository; do not copy a divergent
inline version. Validate it before installation:

```bash
systemd-analyze verify install/systemd/mbweb.service
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

`mbweb` is designed to run locally on `127.0.0.1` and to be exposed through Apache.

Example public path:

```text
/mediabotv3dev/
```

Example local target:

```text
http://127.0.0.1:4002/mediabotv3dev/
```

Enable the required Apache modules:

```bash
sudo a2enmod proxy proxy_http headers
sudo systemctl reload apache2.service
```

The maintained example is `install/apache/mbweb.conf.example`. Its application
path must be adapted together with `MBWEB_BASE_URL`. The required runtime core
is:

```apache
ProxyPreserveHost On

ProxyPass        /mediabotv3dev/ http://127.0.0.1:4002/mediabotv3dev/
ProxyPassReverse /mediabotv3dev/ http://127.0.0.1:4002/mediabotv3dev/

RequestHeader set X-Forwarded-Proto "https"
```

The maintained example also sends this optional metadata:

```apache
RequestHeader set X-Forwarded-Prefix "/mediabotv3dev"
```

MBWEB does not derive its mount path from `X-Forwarded-Prefix`. The normalized
`MBWEB_BASE_URL` value is authoritative for routes, generated links and the
session-cookie path. The optional header may therefore be omitted when the
Apache `ProxyPass` path and `MBWEB_BASE_URL` already match.

After installing or updating the virtual host, reload Apache and verify the
systemd unit plus the public health endpoint:

```bash
sudo systemctl reload apache2.service
sudo systemctl is-active --quiet apache2.service
curl --fail --silent --show-error https://your-host.example/mediabotv3dev/health
```

If you use a different public path, update both:

```text
Apache ProxyPass path
MBWEB_BASE_URL
```

They must stay consistent.

### Important note about secure cookies

When `NODE_ENV=production`, `mbweb` marks the session cookie as secure.

That is correct for an HTTPS deployment, but Apache must tell the Node.js application that the public request is HTTPS. This is why the reverse proxy example includes:

```apache
RequestHeader set X-Forwarded-Proto "https"
```

Without that header, login may appear to work but the browser may not keep the session cookie correctly behind the reverse proxy.

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

npm test
node -c app.js
find lib -maxdepth 1 -name '*.js' -print -exec node -c {} \;
find routes -maxdepth 1 -name '*.js' -print -exec node -c {} \;
```

`npm test` is the deterministic MB723 application lane. It uses Node's
built-in test runner and does not start Express, contact MariaDB, read live
credentials or make network requests. Database and upstream outcomes are
supplied through bounded fakes at the adapter boundary. The lane covers
configuration and secret rejection, authentication and roles, request and SQL
bounds, repository result shapes, safe HTTP errors, radio/metrics/Partyline
limits, listener startup and shutdown behavior, persistent session failure
semantics, session rotation, CSRF enforcement and bounded login throttling.

MB723-C also keeps an explicit read-only capability catalogue. The channel
detail page and its JSON endpoint report Hailo, Gemini, Spark and Fullop as
`enabled`, `disabled` or `unavailable`, including the accepted Hailo and Spark
sub-capabilities. The query reads `CHANSET_LIST` and `CHANNEL_SET` with a fixed
allowlist; it never changes channel policy.

This Node lane is distinct from the Mediabot Perl fast lane. Both are required
for a 3.5 engineering round; neither is a substitute for the release gate's
single explicitly scheduled full suite.

Check current dependencies:

```bash
npm ls --depth=0
```

---

## Public home page behavior

The public home page should stay intentionally quiet.

Before login, it should show a simple landing page and a login entry point only. It must not expose:

```text
database user / host / name
global user count
global channel count
Prometheus metrics endpoint
internal metrics values
```

Those details belong to authenticated users, and the most sensitive operational views should remain reserved for Owner-level accounts.

Useful check:

```bash
curl -s http://127.0.0.1:4002/mediabotv3dev/ \
  | grep -Ei 'Base Mediabot|Entries in USER|Entries in CHANNEL|Prometheus|live metrics' \
  || echo "OK: public home is not leaking dashboard details"
```

Expected result:

```text
OK: public home is not leaking dashboard details
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

## Suggested pre-commit checks

From the Mediabot repository root:

```bash
cd /home/mediabot/mediabot_v3

git status --short contrib/mbweb

node -c contrib/mbweb/app.js
find contrib/mbweb/lib -maxdepth 1 -name '*.js' -print -exec node -c {} \;
find contrib/mbweb/routes -maxdepth 1 -name '*.js' -print -exec node -c {} \;

grep -Rni "SELECT \*" contrib/mbweb || true
grep -Rni "teuk.org" contrib/mbweb || true

find contrib/mbweb \
  \( -name '.env' -o \( -name '.env.*' ! -name '.env.sample' \) -o -name 'node_modules' -o -name '*.bak*' -o -name '*.log' -o -name '*.zip' -o -name '*.tar.gz' \) \
  -print
```

Expected results:

```text
no SELECT *
no teuk.org
no real .env
no node_modules
no backup/log/archive files
```

---

## Notes

`mbweb` is a contributed web console accepted into the Mediabot 3.5 supported
surface after MB723-A through MB723-D. It remains subject to MB724,
supported-instance convergence and observation, release reproduction, the
final Debian 13 gate and the explicit 3.5 release decision.

Promotion keeps the console read-only by default. New general bot, channel or
database mutation controls are outside MB723; the existing owner-only local
cache clear remains a maintenance action and must cross the same CSRF and
session boundaries as every other state-changing request.

The live app can evolve under `/opt/mbweb/app`; when ready, copy the cleaned source back into `contrib/mbweb`, excluding local runtime files and secrets.

Do not publish local synchronization scripts unless they are generic and safe for other users.
