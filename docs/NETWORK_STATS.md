# IRC network statistics and public dashboards (MB827)

Mediabot can record the aggregate counts announced by `/LUSERS` and display
an interactive dashboard on a web server. The bot never needs IRC operator
privileges. It exports no nicknames, channel names, hostmasks or message content.

## What is measured

| IRC numeric | Dashboard field | Meaning |
| --- | --- | --- |
| 251 | `users` | Sum of the explicitly announced visible and invisible users |
| 251 | `visible_users`, `invisible_users` | The two actual counts; never inferred from a different total |
| 251 | `servers` | Network server count as announced by the answering server |
| 252 | `operators` | IRC operators reported online, not channel operators |
| 253 | `unknown_connections` | Unknown connections on the answering server |
| 254 | `channels` | Channels formed, as reported by the network |
| 255 | `local_users`, `local_servers` | Clients and server links on the answering server |
| 265 | `local_users`, `local_users_max` | Current and maximum local clients; explicit 265 takes precedence |
| 266 | `global_users`, `users_max` | Current and maximum global users announced by the server |

A network may hide or restrict some counters. Omitted numerics are **unknown**,
not zero; a numeric explicitly containing zero is stored as zero. The service
cannot reveal hidden counts the IRC server does not supply. If 251's visible +
invisible sum differs from 266, both observations are retained with their scope.
If no supported 251 is available, a valid 266 can supply the total without a
fabricated visibility breakdown. Maximum counts are the IRC server's reported
peaks, not the dashboard's retention-window maximum.

Numerics are assembled within one reply burst, after at least two seconds of
quiet. A new 251 or a disconnect clears the unfinished previous cycle. A sample
requires the 255/266 end of the reply and a valid user total. Late replies are
bounded; fields from older replies are never used to fill a new observation.
The existing Prometheus gauges, partyline `.lusers` and polling remain available.

## Dashboard (MB831)

- Subdued responsive dark design, no animation/flashing or external assets;
  four summary cards with sparklines and period deltas; eleven plots covering
  all twelve raw counters plus visibility proportions, net hourly change,
  users/server, users/channel and operators per 1,000 users. Reported peaks
  and the distinct 266 global count are optional dashed series.
- Complete table: latest snapshot, period delta, minimum, mean, maximum with
  date, median, P95, population deviation and number of observations.
- 1h/6h/24h/7d/30d/90d, refresh every 60s while visible, series toggles,
  synchronized cursor, pointer/keyboard tooltips, drag zoom and optional
  zero-origin axes. Escape, double click or reset leaves zoom. Cards/tables
  keep the full selected period when a curve is zoomed.
- Accessible observation table and CSV download of **displayed real samples**
  only, UTC timestamps, all twelve raw columns, empty unknown values. This is
  not an unbounded raw-database export.
- True min/max/mean/median/P95/deviation/deltas across **all raw samples** for
  each present field. Means/deviation are not time weighted; P95 uses the upper
  nearest rank. Delta = last minus first; percentage is unknown if first=0.
  First/last/min/max timestamps are also in JSON. A single point has zero
  delta, not an established trend.
- Coverage merges each sample's following declared-cadence slot, clipped to
  now/the requested window, divided by requested duration. It estimates
  measured slots, **not network uptime**. A newly activated history can have
  low coverage on a long period. Gaps count interior separations >2.5 cadences;
  range edges are not called gaps. Observation age is displayed separately.
- An indexed chronological scan computes the statistics and retains at most
  601 actual last observations per time bucket, without a bucket/history join.
  A hidden within-bucket peak remains in raw-period statistics; the graph does
  not invent it. Ratios use counters in one displayed sample. Net hourly rate
  uses adjacent **raw** observations within 2.5 cadences before downsampling;
  it is not a join/quit counter. Ratio and zoom footers summarize shown values.
- Users/channel is not actual average membership (one user can join many
  channels). Numeric 251/266 and local/global scopes remain distinct. Peaks
  advertised by the server are not historical maxima. Missing fields and
  gaps remain visible, zero remains zero, old observations are marked stale.
- Browser-local times and explicit timezone footer; storage and CSV in UTC.
  No CDN, tracking, Grafana or Prometheus dependency.

Open `contrib/network-stats/preview.html` for a self-contained design preview
with **simulated data**, no connections to running instances. Use `upgrade.py`
to update an installed hub without recreating its stream profile; see
[LIBERA_NETWORK_STATS.md](LIBERA_NETWORK_STATS.md). History starts at activation;
no past measurements are manufactured.

## Simple installation: one Mediabot and one web server

Only two optional bot settings are needed:

```ini
[network_stats]
ENABLED=1
OUTPUT_FILE=var/network-stats.json
```

The path is relative to the bot's working directory. The default polling remains
`main.LUSERS_REFRESH=300` (five minutes, bounded 60–3600; zero disables polling).
The exporter itself performs no DNS, HTTP or SQL work on the IRC event loop.
Its atomic snapshot is private to the bot account (0600).

Run the independent Python 3 standard-library hub on loopback behind the web
server's existing HTTPS vhost. Install `network_stats.py` and `static/` into a
root-owned application directory. The hub needs one writable directory for its
SQLite database. Generate a random, per-instance publisher token with
`secrets.token_urlsafe(36)`; keep it out of Git and store only its SHA256 in the
hub's private configuration. For example, with your real paths and generated
credential values substituted:

```json
{
  "bind": "127.0.0.1",
  "port": 9409,
  "database": "/var/lib/mediabot-network-stats/history.sqlite3",
  "streams": {
    "my-network": {
      "label": "My IRC network",
      "token_sha256": "YOUR_GENERATED_SHA256_HEX_VALUE"
    }
  }
}
```

Publisher configuration, readable only by the bot account:

```json
{
  "url": "http://127.0.0.1:9409/network-stats-api/ingest/my-network",
  "token": "YOUR_GENERATED_PUBLISHER_TOKEN",
  "snapshot": "/home/mediabot/mediabot_v3/var/network-stats.json",
  "state": "/var/lib/mediabot-network-stats-publisher/my-network.sqlite3"
}
```

Run `python3 -B network_stats.py serve --config /absolute/hub.json` as a
separate unprivileged account. Run `python3 -B network_stats.py publish --config
/absolute/publisher.json` as the bot account on a 30-second systemd timer. Both are separate
from the bot's lifecycle. For a remote URL, HTTPS with normal certificate and
hostname verification is mandatory; redirects and proxy environment settings
are refused. HTTP is allowed only to a literal loopback address.

Proxy exactly `/<stream>`, `/network-stats-api/` and `/network-stats-assets/` to
the loopback hub, preserving the paths. Do not expose the hub listener, SQLite
file, private config or source directory as a document root. No port on the bot
host needs to be opened for incoming telemetry.

For a single bot, the same setup helper can generate the configs and services
for one stream instead of the Teuk two-host profile:

```bash
sudo -n python3 -B contrib/network-stats/setup.py hub \
  --site-url https://irc.example.org \
  --stream 'network=Our IRC network' --local-instance network \
  --apache-vhost /etc/apache2/sites-available/YOUR_TLS_VHOST.conf
```

This is a read-only plan. Repeat with `--apply` after review. The vhost's
`ServerName` must match `--site-url`; the page is then `/network`. The helper
expects the Unix bot account `mediabot`; deployments under another account can
adapt the explicit service/config templates. Repeat `--stream SLUG=LABEL` for
more streams. Private file paths are generated, never stored in the bot config.

## Teuk.org hub: dev, Undernet, EpikNet and Libera

| Host | Role | Output |
| --- | --- | --- |
| `teuk.org` | Dev bot + local publisher + dashboard hub | `https://teuk.org/mbdev` |
| `teuk.org` | Undernet bot in `mediabot3`, using `mbundernet.conf` | `https://teuk.org/undernet` |
| `nbot.soyou.rocks` | EpikNet bot + outgoing HTTPS publisher | `https://teuk.org/epiknet` on teuk.org |
| `mediabot.teuk.org` | Libera bot + outgoing HTTPS publisher | `https://teuk.org/libera` on teuk.org |

The initial setup helper creates the dev/EpikNet pair. Add the local Undernet
stream to an existing installation with `add_local.py`, following
[UNDERNET_NETWORK_STATS.md](UNDERNET_NETWORK_STATS.md). It preserves the existing
streams and uses the absolute `mediabot3` snapshot, not the dev export. The
Undernet bot can already collect LUSERS once its own config enables export;
it does not require a different IRC operator role or a new bot implementation.

Source installation and all
required tests come first. The source package does **not** activate anything,
edit private configuration or restart a running bot.

### 1. Inspect the web host

As `mediabot` on **teuk.org**:

```bash
(
  set -Eeuo pipefail
  cd /home/mediabot/mediabot_v3
  sudo -n python3 -B contrib/network-stats/setup.py audit
)
```

Identify the actual TLS vhost file from `apache2ctl -S`; do not guess a filename.
The helper accepts exactly one TLS `:443` vhost with `ServerName teuk.org` in the
selected file. Ambiguous multi-vhost files require a reviewed manual Include.
Existing `/mbdev`, `/epiknet`, `/network-stats-api` or `/network-stats-assets`
applications must be moved or explicitly reviewed before using these paths.

Preview, replacing the path with the verified vhost file:

```bash
sudo -n python3 -B contrib/network-stats/setup.py hub \
  --apache-vhost /etc/apache2/sites-available/YOUR_TEUK_TLS_VHOST.conf
```

Only after reviewing the plan, repeat with `--apply`. The helper:

- Backs up managed files privately under `/var/backups/mediabot-network-stats-*`.
- Installs a dedicated `mbnetstats` account and loopback hub under
  `/opt/mediabot-network-stats`; SQLite lives under
  `/var/lib/mediabot-network-stats` and survives repository updates/reboots.
- Generates independent tokens for `mbdev` and `epiknet`; reruns retain the
  existing credentials and history. A missing publisher token must be restored
  from its private backup; it cannot be reconstructed from the hash.
- Installs the local dev publisher and systemd timer as `mediabot`.
- Adds one scoped Include to the existing TLS vhost, validates Apache and the
  units, starts the hub, then checks both public data URLs through HTTPS.
- On failure, restores managed files and the previous active service state;
  keeps history databases and the recovery backup. A newly created system
  account or enabled Apache proxy module can remain unused after rollback.

`setup.py` manages `mediabot-network-stats.service` and
`mediabot-network-publish-<instance>.service/.timer`; it does not stop or change
`mediabot@dev.service`, `mediabot@nbot.service`, mbweb or another web application.
The setup is separate from `commit.sh`. Later dashboard updates use the
scoped `upgrade.py`, retaining every existing stream. The bot updater never
deploys the web host's application automatically.

### 2. Activate the dev export using the native config writer

Avoid manual live edits: Mediabot can save its in-memory configuration. On
teuk.org, use the exact running dev instance and its real config path. Verify
`systemctl cat mediabot@dev.service` and `/etc/default/mediabot-dev` first.
Substitute its real configuration filename below if different:

```bash
(
  set -Eeuo pipefail
  cd /home/mediabot/mediabot_v3
  sudo -n systemctl stop mediabot@dev.service
  trap 'sudo -n systemctl start mediabot@dev.service' EXIT
  cp -p mediabot.conf "mediabot.conf.before-network-stats-$(date +%Y%m%d_%H%M%S)"
  perl -I. -MMediabot::Conf -e '
    my $c=Mediabot::Conf->new({},"mediabot.conf");
    $c->set("network_stats.ENABLED",1);
    $c->set("network_stats.OUTPUT_FILE","var/network-stats.json");
    $c->save;
    my $r=Mediabot::Conf->new({},"mediabot.conf");
    die "Cannot reread setting\n" unless $r->get("network_stats.ENABLED")==1;
    print "[OK] Network stats export configured.\n";
  '
)
```

After the bot reconnects, a fresh reply and one publisher timer cycle should
populate `/mbdev`. Start/reload behavior depends on the actual verified unit.
The setup helper cannot know a private instance's filename from a source archive.

### 3. Install the EpikNet publisher on nbot

The hub creates `/home/mediabot/network-stats-epiknet.private.json`, owner
`mediabot`, mode 0600. Transfer this **private** file to nbot through your existing
SSH route. Never attach it to chat, publish it via the website or commit it.
It contains only the per-stream publishing token and aggregate snapshot paths.

Commit the tested source with `commit.sh`, then update nbot with `!update now`.
On **nbot**, as `mediabot`, preview the publisher install:

```bash
(
  set -Eeuo pipefail
  cd /home/mediabot/mediabot_v3
  sudo -n python3 -B contrib/network-stats/setup.py publisher \
    --instance epiknet \
    --publisher-config /home/mediabot/network-stats-epiknet.private.json
)
```

Repeat with `--apply`. Activate `[network_stats]` through the same native config
writer procedure, using **`mediabot@nbot.service`**. The private publisher file
is installed at `/etc/mediabot-network-stats/epiknet.publisher.json`. No incoming
port, shared database, shell account on teuk.org or SSH key is needed at runtime.
An old snapshot is never resent with a new timestamp.

### 4. Verify the actual end-to-end path

For each instance, inspect its export and publisher service locally. These
commands contain no credentials:

```bash
stat -c '%U:%G %a %n' /home/mediabot/mediabot_v3/var/network-stats.json
systemctl --no-pager status mediabot-network-publish-epiknet.timer
sudo -n journalctl -u mediabot-network-publish-epiknet.service -n 15 --no-pager
curl --fail --silent --show-error https://teuk.org/epiknet/data?range=1h
```

Use `mbdev` on teuk.org. Compare a fresh `/LUSERS` reply to the latest observation,
check missing-vs-zero numerics and the actual network label, then verify that
both graphs accumulate independently. Stop a publisher briefly in an isolated
acceptance window, let it retry, and confirm no cross-instance samples or
unacknowledged losses. Do not interrupt a production bot for a dashboard test.
A dashboard response alone does not prove live collection; confirm an increasing
sample timestamp and matching current IRC counts.

## Persistence, bounds and operation

- Snapshot: private `var/network-stats.json`; regenerated after reconnect/update.
  It is a current observation, not the historical database. Do not rely on the
  updater retaining this replaceable snapshot; the durable history/outbox live
  outside the repository.
- Publisher: SQLite outbox outside the repo, kept for up to 30 days / 10,000
  observations. It captures the latest export per run, retries bounded batches
  of 256 and deletes only after an exact successful acknowledgment. Very fast
  manual refreshes between publisher runs can coalesce into one observation.
- Hub: 90-day retention, at most 50,000 samples per stream, at most 16 streams.
  Defaults produce 288 samples/day per bot. Queries are parameterized; public
  responses include only configured display labels and aggregate values.
- One successful burst creates one observation, not one row for every numeric.
  The independent publisher keeps network latency off the IRC loop.
- Credentials are per stream; one publisher cannot write the other stream.
  Rotate a token by replacing its private publisher file and matching hub hash,
  then restart the hub. Service logs contain counts/error classes only.
- Back up the SQLite history using SQLite's backup API while live, or stop the
  hub before copying the database and its WAL. Keep private configs separately.
- Inspect `mediabot-network-stats.service` for hub errors; the `/health` endpoint
  is `/network-stats-api/health`. Stale status uses observation age, not web uptime.

## Validation

Run `python3 -B contrib/network-stats/test_network_stats.py` for real loopback
HTTP/SQLite/publisher tests. `perl t/test_commands.pl --filter mb827 --progress`
also runs these tests and the actual core numeric/export integration. Use the
full project suite before committing. The visual preview is fixture data; only
host-side collection, TLS reverse proxy and a live `/LUSERS` comparison establish
production acceptance.

MB831 regression checks cover statistics/coverage, raw-rate downsampling,
chart gaps/ratios, remote host binding, scoped upgrade/rollback and native
config activation. The pure chart tests use Node.js (`node --test
contrib/network-stats/test_dashboard.js`), required for this dashboard development lane only,
not for the bot's full Perl/Python suite or the Python runtime. No npm installation is required for these tests.

## Dashboard language

Every stream page opens in **English** unless that browser has explicitly
selected **Français** in the header. The language choice is shared by all
dashboard streams on the same origin and persists across reloads. Browser
language does not change the English default.

The selector updates headings, eleven charts, legends, keyboard instructions,
hover tooltips, summary tables, collection/error notices and methodology in
place. Dates and numbers use `en-GB` or `fr-FR`, with the browser’s existing
local time zone. Network labels and raw IRC counter identifiers keep their
configured meanings. CSV headers and UTC ISO timestamps stay stable.

A language change neither requests new measurements nor resets the selected
time range, zoom, hidden series or zero-axis setting. Publication errors remain
visible while the last good measurements stay on screen.

The only saved browser setting is the non-sensitive
`mediabot.networkStats.language` preference (`en` or `fr`) in local storage.
If storage is denied, the dashboard remains usable and language can still be
changed for that page; it starts in English again on the next load. No cookie,
login, external translation service or new server configuration is required.

Deploy through `contrib/network-stats/upgrade.py` to update every configured
stream together, preserving the history database, stream credentials, managed
routes, bot processes and publisher timers. Reviewed pre-MB831, MB831, MB832 and
already-current assets are accepted; unrelated local asset edits are refused.

## Historical navigation and period comparison (MB833)

Use **Earlier / Later / Live** below the time-range controls to inspect retained
history. The date strip always states the selected interval in browser local
time. Historical status describes that interval, not current network health.
Returning within one minute of the latest live endpoint selects Live, avoiding
a view stranded a few seconds behind the moving server clock.

**Compare previous period** overlays the preceding equal elapsed duration with
subdued dashed curves. All eleven charts retain series visibility, explicit
zeros, unknowns and collection gaps. The previous-period timestamp appears in
tooltips; nearby previous samples are used only within 1.25 sample intervals,
never interpolated across a wide gap.

The raw-counter table adds previous mean, difference between means and percent
change. A difference requires at least two actual samples of that counter in
each period. A zero previous mean has no percentage change. Means are sample
means without time weighting; compare each period’s coverage and sample count
before interpreting them. Different coverage can bias a comparison. These are
network-counter observations, not unique audiences or individual join/part counts.

The joining boundary belongs to the selected period; it is excluded from the
comparison period to prevent double counting. Both periods use fixed elapsed
durations, not civil calendar days: a daylight-saving transition can therefore
align different local hours. Earlier/Later standalone views keep the historical
API’s closed endpoint convention; the comparison baseline explicitly excludes
the joining endpoint.

Cards show observed lows and peaks, with their timestamps in the title. Raw
current-period extrema are marked on charts when not zoomed, including an
extreme that is absent from the downsampled display points. In a zoomed chart
the summary strip continues to describe displayed points; cards and the raw
statistics table retain the full selected interval.

**Copy view link** produces a link with a fixed server endpoint, selected range
and comparison flag. A copied live view becomes historical for its recipient
while the original page keeps updating. The browser’s language preference
remains local. Drag zoom and hidden-series settings are not included in the
shared link. Clipboard failure displays the link as selectable plain text.
A link can reproduce its period only while the underlying history is retained.

The accessible observations table contains both periods, with original UTC
instants formatted in browser local time and an explicit period label. CSV
exports keep their previous raw identifiers and ISO UTC timestamps, and contain
only selected-period display observations.

### Public history API

`/<stream>/data?range=24h&end=<Unix-seconds>&compare=1` accepts the existing
range names. `end` is optional; omitting it selects the moving live endpoint.
It must be an integer strictly newer than the current retention cutoff and no
later than the actual server clock. `compare` accepts only `0` or `1`; duplicate
or unknown query parameters are rejected.

Legacy response fields remain available. `now` is the selected endpoint;
`server_now` is the actual request-time clock. `live`, `retention_from` and
`first_available` describe the selection and retained history. With comparison
enabled, `comparison` contains its own interval, summary, points and quality.
Coverage can be partial when a requested window crosses the retention cutoff;
`quality.retention_clipped` reports that case. The 90-day baseline can be empty
because data older than 90 days is not retained.

Both disjoint windows are read in the same database transaction, using bounded
indexed scans with at most 601 actual display points per period. There is no
schema migration, new stream credential, remote publisher change or IRC restart.
Deploy the reviewed source through `upgrade.py` on the existing hub host.
