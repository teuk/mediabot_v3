# Mediabot ShortURL

This contribution provides one small URL service for a Mediabot installation:

- public immutable redirects at `https://HOST/shorturl/<id>`;
- authenticated creation at `POST /shorturl/api/v1/links`;
- one random 256-bit bearer token per authorized Mediabot instance;
- idempotent SQLite storage and non-sequential random identifiers;
- a loopback-only Waitress process behind the site's existing HTTPS Apache
  virtual host.

Redirects must be public so IRC users can follow them. Creation is never public:
the service accepts only registered instance tokens and applies a per-token
request budget.

The canonical source stays in `contrib/shorturl`; deployment copies it to the
read-only runtime directory `/opt/mediabot-shorturl/app`. Durable data and the
hash-only service configuration live in `/var/lib/mediabot-shorturl`.

Mediabot uses the service through `Mediabot::URLShortener`. RSS polling,
`rss show`, `rss probe` and interactive news therefore share the same private
cache and failure circuit. On every failure, the exact original URL remains in
the IRC output.

## Dependencies

Debian 12 and Debian 13 packages:

```bash
sudo apt-get install apache2 python3 python3-waitress
sudo a2enmod proxy proxy_http headers
```

The service contains no framework-specific application dependency. Waitress is
the bounded production WSGI server and SQLite is provided by Python itself.

Before changing Apache, collect the read-only host report:

```bash
contrib/shorturl/audit_host.sh
```

Install the loopback service only after the report confirms that port 8766 is
free and the required packages are present:

```bash
sudo contrib/shorturl/install_service.sh
```

The installer runs the offline service tests, creates a versioned runtime,
preserves an existing database and token hashes, verifies the systemd unit and
checks the loopback health response. It does not modify Apache.

## Initial state

Create `/var/lib/mediabot-shorturl` as the Unix account that will run the
service, then initialize it as that account:

```bash
sudo install -d -m 0700 -o mediabot -g mediabot \
  /var/lib/mediabot-shorturl

sudo -u mediabot /usr/bin/python3 \
  /opt/mediabot-shorturl/app/shorturl_admin.py init \
  --public-base https://teuk.org/shorturl/ \
  --identity dev \
  --credential-output /home/mediabot/shorturl-dev.token
```

The clear token is written once to the requested owner-only file and is never
printed. The server configuration stores only its SHA-256 digest.

Issue another independent credential with:

```bash
sudo -u mediabot /usr/bin/python3 \
  /opt/mediabot-shorturl/app/shorturl_admin.py issue \
  --identity nbot \
  --credential-output /home/mediabot/shorturl-nbot.token

sudo systemctl restart mediabot-shorturl.service
```

The application client sends that token only in the HTTPS Authorization header.
No SSH credential or inter-host filesystem access is involved at runtime.

Once the credential file is present on its intended Mediabot host with mode
0600, configure that instance without putting the token in command history:

```bash
python3 contrib/shorturl/configure_client.py \
  --config /home/mediabot/mediabot_v3/mediabot.conf \
  --credential /home/mediabot/shorturl-dev.token
```

The updater makes one owner-only `.pre-mb736` backup, preserves unrelated
sections, installs the four `[shorturl]` values and makes the resulting
configuration owner-only. The API URL is derived from the public base, so a
configuration error cannot send the bearer token to a different origin.

Existing installations with only `[tinyurl]` configured retain mb735 behavior
until `[shorturl]` is complete. A partial or invalid `[shorturl]` section fails
closed to original URLs and never falls back to a different provider.

## Apache boundary

Copy the directives from `apache-shorturl.conf.example` inside the existing
`*:443` virtual host for the public hostname. Do not enable them globally: the
same Apache process may serve unrelated names.

Place the `/shorturl/` `ProxyPass` before any broader proxy rule. Validate with
`apache2ctl configtest`, reload rather than restart, then test one authenticated
creation and its public redirect. The creation endpoint remains unreachable
without a registered bearer token even though redirects must be public.

The backend health endpoint is deliberately available only on loopback:

```bash
curl --fail --silent --show-error http://127.0.0.1:8766/healthz
```

Apache exposes only `/shorturl/`. It forwards creation requests and public
redirects to the same loopback service; the backend enforces their distinct
authorization rules.

After reloading Apache, verify both authorization and destination binding
without putting the token in the command line or output:

```bash
python3 contrib/shorturl/verify_live.py \
  --credential /home/mediabot/shorturl-dev.token
```

## Administration

The administration tool never lists URLs or token hashes:

```bash
sudo -u mediabot /usr/bin/python3 \
  /opt/mediabot-shorturl/app/shorturl_admin.py list

sudo -u mediabot /usr/bin/python3 \
  /opt/mediabot-shorturl/app/shorturl_admin.py inspect
```

Revocation updates the private configuration and requires one controlled
service restart before it takes effect.

## Privacy and logs

Application logs contain only the authenticated client identity, generated
identifier and whether the mapping was new. They never contain the bearer
token or destination URL. Apache access logs naturally contain the public
identifier, but creation puts the destination in a bounded JSON body rather
than in the query string.
