# Radio requests

On a channel with **`+Radio`**, every participant can use:

```text
m play https://www.youtube.com/watch?v=VIDEO_ID
m play Michael Jackson Billie Jean
m rplay Radiohead
m rplay Idioteque
m radioqueue
m queue
m nextsong
```

`play` accepts an artist/title search or one HTTPS YouTube video URL. Text
search chooses the first eligible video among YouTube's first five results,
in relevance order. It excludes known live/upcoming videos and entries with
missing, invalid or excessive duration (15 minutes by default). Use a video
URL when you need a particular recording; spelling correction and the exact
musical version are not guaranteed.

The chosen video ID is recorded before downloading. An interrupted request
resumes with that same ID. The service reuses an available MP3 or downloads
it, registers it in the central `MP3` table, then submits it to Liquidsoap.
Search runs centrally with the same private tools and cookie-copy policy,
a 30-second deadline and at most one audio download per request. It shares
YouTube pauses, queue limits and duplicate prevention with URL requests.
An empty eligible search allows a corrected request after five seconds;
other errors retain the normal cooldown. Search does not add extra IRC messages.

`rplay` chooses randomly among matching artists (exact artist first, then
partial artist), falling back to title matches. Unavailable files are skipped;
it does not download a search result. Up to 200 catalogue candidates are
examined per search, with a total 30-second scan budget and at most five
seconds per candidate probe. Existing administrative queue controls remain restricted.
Outside `+Radio`, the historical Master-only `play` command is unchanged.
`+RadioPub` is a separate announcement setting.

Existing MB734 HTTP clients already transmit text queries. Once the central
service supports text `play`, configured instances can use it without new
keys; updating clients also provides the new help and specific search errors.
Each additional instance still needs its own API token, API URL and `+Radio`
on the chosen channel. MP3 files and the catalogue stay on the radio host.
The bounded search uses yt-dlp's documented
[YouTube search prefix](https://github.com/yt-dlp/yt-dlp#usage-and-options).

Preparation, errors and throttling remain private NOTICEs. A successful addition
uses one orange/grey channel line, matching `song`, when the shared public
spacing permits; otherwise the same confirmation is sent by NOTICE.
“Added to the queue” means Liquidsoap
returned a request ID; it does **not** mean that playback has already started.
The API neither skips a track nor changes a streaming script. Live priority
and track interruption follow the existing Liquidsoap configuration. In
particular, `track_sensitive=false` between playlist and queue can interrupt
the playlist when a request becomes ready. Qualify this policy separately
before promising that the current track will always finish.

## See what is waiting

| Command on `+Radio` | Result |
| --- | --- |
| `m song` | Current Icecast title and listening URL, as before. |
| `m radioqueue` | One compact line: Icecast current title, first three waiting requests, remaining count. Public at most once per minute per channel; NOTICE otherwise. |
| `m queue` | Alias for `m radioqueue` on `+Radio`, with the same permissions and cooldown. |
| `m nextsong` | One NOTICE with the first waiting request, or an empty-queue indication. |

The read-only commands work for every participant through the same authenticated
API, including remote bots. They do not use the remote host's Liquidsoap socket.
No new setting or migration is needed when `play`/`rplay` already use the API.
Update the central API first, then the IRC clients through the usual update flow.

A client predating shared queue support can still request tracks through the
central API while its old `radioqueue` command tries a local Liquidsoap socket.
Update that client to the published shared-queue version; do not point its local
telnet settings at a remote streaming control socket. On `+Radio`, queue reads
use the HTTP API and never fall back to local telnet, including API failures.

Artist and title are presented consistently in request confirmations, the shared
queue and metadata sent to Liquidsoap. A title beginning with the same artist
and a separator (for example `Artist - Song (Official Video)`) loses that repeated
prefix. Recording/version suffixes remain. This also applies to existing MP3
catalogue entries at their next submission, without retagging audio or rewriting
old database rows. Metadata already on air is not changed retroactively.

The queue comes from Liquidsoap's actual pending request IDs, not the history of
accepted requests. It is shared between authenticated instances; private request
history remains isolated. The API keeps its six-title response for existing
clients; IRC shows the current Icecast title and only the next three requests,
plus a count of any remaining tracks. Missing Icecast status is displayed as
“title unavailable”, while the waiting queue remains usable.

Public output uses orange (07) capsules and grey (14) music labels, without a
background colour, in the same theme as `song`. Each queue response is one line,
bounded to 360 UTF-8 bytes including formatting. Long labels are shortened.

### Channel output budget

- `queue` and `radioqueue` share one public view per **60 seconds per channel**,
  across all callers. Further eligible reads use the same compact view by NOTICE.
- Confirmed additions and public queue views share a **15-second public gap**.
  A suppressed public success still reaches its requester by NOTICE.
- `nextsong`, preparation, errors and refusals are always private.
- One caller identity may consult every **five seconds**, across aliases/nicks;
  the bot also limits consultation responses to one per second overall. Faster
  repetitions are ignored. At most one HTTP queue read is started every five
  seconds per bot, with a five-second response cache for nearby requests.
- `song` retains its existing output and behavior. These budgets do not announce
  spontaneous queue changes, alter audio priority, or change request cooldowns.

The public display budget is bounded in memory per bot/channel; instances on
separate IRC networks therefore have independent channel output. The API queue,
download limits and request deduplication remain shared.

### Confirmed position

After a numeric push acknowledgement, the service reads the real waiting IDs
twice within a shared two-second deadline. A stable list yields the request's
one-based **position at addition**, not an estimate from the queue length before
pushing. This observation is kept in a small private SQLite `queue_receipts`
table and returned with that job; polling or restarting does not recompute it.

If the request has already left the waiting list, the confirmation says
“no longer waiting”. A failed/changing read says “position unconfirmed”. Neither
case repeats an acknowledged push or turns it into a failed request. Existing
queued jobs without a receipt remain valid and have no invented rank. No
MariaDB schema, catalogue row or audio file is changed by this observation.

Leaving the waiting list alone does not establish what is broadcast. The current
title comes from the configured Icecast mount; Liquidsoap also cautions against
using request-level on-air metadata as output truth in its
[2.3 migration notes](https://www.liquidsoap.info/doc-2.3.1/migrating.html).
Live input keeps priority and no start time is promised. A failed queue read is
never presented as an empty queue. `nextsong` describes the next *requested*
track, not the fallback playlist or live input.

## One host: the default installation

Run one radio API process on the same host as Mediabot, its database and
Liquidsoap. Clients POST to `http://127.0.0.1:8765`; no SSH or HTTPS certificate
is required for this local connection. The API binds to loopback only.

1. Install Python 3 (3.9+), `python3-waitress`, ffmpeg and yt-dlp on the radio
   host, alongside Mediabot's existing Perl DBI/MariaDB dependencies. Configure
   a supported JavaScript runtime for yt-dlp (the initializer selects Node).
   Keep yt-dlp maintained independently; this feature does not update it.
2. Identify the actual Liquidsoap request queue with its read-only `help`
   command. Set `LIQUIDSOAP_TELNET_HOST=127.0.0.1`, its local control port and
   `LIQUIDSOAP_QUEUE_ID` in `[radio]`. Configure the downloader's `YTDLP_PATH`
   and, if needed, `YTDLP_COOKIES_FILE` / `YTDLP_REMOTE_COMPONENTS` there.
   Streaming ports and control ports are different endpoints.
3. Create the shared store. Adapt account and streaming group to the installation:

   ```sh
   sudo install -d -o mediabot -g liquidsoap -m 2750 \
     /var/lib/mediabot-radio /var/lib/mediabot-radio/incoming
   ```

4. As the bot account, from the repository, initialize the private state:

   ```sh
   python3 -B contrib/radio_init.py --bot-config "$PWD/mediabot.conf"
   ```

   If the catalogue is empty or has several owners, pass `--owner-id ID` for
   an **existing central Mediabot user**. New guest downloads belong to this
   catalogue owner; a remote instance's numeric user ID is never used. No
   new user, grant or MP3 schema is created. Instance/channel/caller-hash
   attribution is kept separately in the private job ledger.

5. Install `tools/systemd/mediabot-radio.service.example` as
   `/etc/systemd/system/mediabot-radio.service`. Adapt its account, repository
   and configuration paths; keep the API in a single process. Then:

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now mediabot-radio.service
   ```

6. Add these keys to the bot's **existing** `[radio]` section:

   ```ini
   RADIO_API_ENABLED=1
   RADIO_API_URL=http://127.0.0.1:8765
   RADIO_API_TOKEN_FILE=/var/lib/mediabot-radio/control/client.token
   ```

   The initializer creates the random token as a private 0600 file. Do not put
   it in Git, a URL, a shell command argument or an IRC message. Server state
   and control directories are private; final MP3s are 0640, readable by the
   streaming group. The bot repository can remain private.

7. Apply `install/migrations/20260911_radio_chanset.sql` through the normal
   migration workflow, restart the selected bot, and enable a pilot channel:

   ```text
   m chanset +Radio
   m rplay <artist already present in MP3>
   ```

   First check the returned queue acknowledgement **and listen to the stream**.
   Next test `play` with a short permitted YouTube video and confirm the MP3
   row/file. `m chanset -Radio` stops new public requests; accepted jobs remain
   accepted. It is not a queue-flush command.

## Several IRC instances

Keep exactly one catalogue, audio store, worker and rate-limit ledger on the
radio host. Each IRC bot uses the same public-command client. Remote bots need
no yt-dlp, ffmpeg, shared filesystem, database access to the radio host or SSH
key. They only need outbound HTTPS and a distinct bearer token.

Place the loopback API behind an existing HTTPS reverse proxy with a valid
certificate. Do not expose port 8765 or Liquidsoap's control socket publicly.
An example **inside the selected TLS virtual host** is:

```apache
ProxyPass        /mediabot-radio/ http://127.0.0.1:8765/ connectiontimeout=3 timeout=10
ProxyPassReverse /mediabot-radio/ http://127.0.0.1:8765/
<Location /mediabot-radio/>
    LimitRequestBody 4096
</Location>
```

Use `proxy`/`proxy_http`, preserve Authorization, and do not enable a forward
proxy. Review and validate the selected virtual host before reloading Apache;
this feature does not install or edit Apache configuration. The client follows
no redirects, ignores ambient HTTP proxies and verifies TLS certificates.

For each additional instance, add a distinct randomly generated 64-hex token's
SHA-256 digest to `token_hashes` in the private server JSON, under a unique
logical name, for example `nbot`. Deliver the token as a 0600 file owned by
that bot account on its host. Restart the API to load a changed registry;
remove that one digest to revoke an instance. Never reuse a token across bots.
Then set the remote bot's URL to `https://YOUR_RADIO_HOST/mediabot-radio` and
its token-file path. `RADIO_API_ENABLED=1` plus the per-channel `+Radio` setting
are both needed. Remote HTTP is rejected even if a token exists.

The authenticated token determines the instance identity; the JSON body cannot
override it. Use unique names even when several systemd instances happen to
be called `prod`. Debian 12 clients and Debian 13 clients use the same Perl
HTTP implementation; the central Python service runs only on the radio host.

## Request contract and limits

- `POST /v1/requests`: JSON `id` (32 hex characters), `caller` (64-hex identity
  hash), `channel`, `action` (`play` or `rplay`), and `query`. Returns 202 with
  a durable ID/state, not a playback promise. No URL fetch target other than
  a validated YouTube video, SQL, filesystem path or player command is accepted.
- `GET /v1/requests/ID`: private status for that authenticated instance only.
- `GET /v1/health`: authenticated liveness check; no playback or download.
- `GET /v1/queue`: shared pending music labels and aggregate preparation counts;
  authenticated and read-only. Player reads share a four-second deadline and a
  single observation lock; submissions retain their independent ledger lock.
- One download/processing worker; six pending/working jobs globally, at most
  one per caller. Cooldowns: 120 seconds per caller, 15 seconds per channel.
  An `rplay` search with no catalogue rows uses a five-second cooldown instead,
  so a typo can be corrected. Other errors retain the normal budget. Replies
  distinguish a pending request, the remaining cooldown and a full queue.
  Video duplicates are suppressed across instances while pending and for ten
  minutes after their last state update. After catalogue resolution, the same
  track is also protected across `play` and `rplay` for ten minutes after
  submission, including lost acknowledgements and restarts. The physical Liquidsoap queue is capped at six
  pending entries for API submissions; administrative tools can still alter it.
- Default track limit: 15 minutes, 32 MiB final MP3. Download timeout 180 seconds,
  scratch limit 128 MiB and at least 512 MiB free before downloading. Local
  cached tracks receive the same audio/duration validation. Cookie files are
  read from private regular files and copied privately for each download,
  preserving the original cookie file. Temporary metadata is size-limited; new
  cached MP3 sidecars include a SHA-256 fingerprint and size. Existing sidecars
  remain supported. A changed fingerprint stops reuse; audio probing forces the
  MP3 demuxer and permits only local file access.
- Retrying the same request ID never creates another job. Once submission to
  Liquidsoap starts, missing acknowledgements or a crash produce `uncertain`;
  the service never automatically pushes that job again. Check the player
  before making a new request. A DB failure before submission never pushes.
- Completed jobs are retained for seven days and pruned on later submissions.
  Logs contain job ID, logical instance, state and error code; no bearer token,
  DB credentials or raw downloader output. A catalogue match whose file is
  rejected produces `catalogue_tracks_unavailable`; `catalogue_skip` diagnostics
  identify the MP3 row and rejection code without disclosing its path to IRC.
  Use `journalctl -u mediabot-radio` for these API diagnostics.
- Downloader errors are classified without publishing raw stderr. A refused
  YouTube session (`youtube_auth_required`) pauses new downloads for five
  minutes; rate limiting (`youtube_rate_limited`) pauses them for fifteen.
  This pause is shared across instances and survives API restarts. During it,
  uncached requests fail with `youtube_paused`; `rplay` and valid cached `play`
  requests continue normally. Paused requests are not replayed automatically.
  Unavailable videos and other download failures do not trigger this pause.
- The additional tables (`download_pause`, `track_claims`, `queue_receipts`) live only in
  the API's private SQLite ledger. Existing jobs and the MariaDB MP3 schema
  are preserved. No new user, migration or grant is required.

The client checks `+Radio` and channel membership, has at most four supervised
HTTP jobs per bot, and suppresses late public/private replies after an IRC reconnect. The API
trusts authenticated bot clients to enforce membership; a public unauthenticated
web player is outside this protocol.

Implementation references: [Waitress server limits](https://docs.pylonsproject.org/projects/waitress/en/stable/arguments.html),
[Apache reverse-proxy configuration](https://httpd.apache.org/docs/2.4/mod/mod_proxy.html#proxypass),
and [yt-dlp options](https://github.com/yt-dlp/yt-dlp#usage-and-options).

## Listen and administer over HTTPS

The Icecast website and the request API have different URLs. For example,
`https://radio.example/radio/radio.mp3` is the stream,
`https://radio.example/radio/admin/stats.xsl` is Icecast administration, and
`https://radio.example/mediabot-radio` is the optional remote request API.
Icecast administration uses the existing Icecast administrator credentials;
it never uses the request API bearer token.

Keep `RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000` and
`RADIO_ICECAST_PRIMARY_MOUNT=/radio.mp3` on the radio host. Set
`RADIO_ICECAST_PUBLIC_BASE_URL=https://radio.example/radio` to generate public
links with the prefix. Generic single-host defaults need no reverse proxy.

A prefix proxy must also rewrite absolute HTML links and playlist contents.
`ProxyPassReverse` alone rewrites response headers, not HTML. Apply
`ProxyHTMLEnable On` and link mappings only to the Icecast prefix; never force
that HTML filter onto audio. Limit any playlist substitution to the `.m3u`
and `.xspf` endpoints. Keep the original mount query values used by Icecast
administration unchanged. Validate the TLS certificate, status page, playlist
URL and unauthenticated admin challenge after an Apache graceful reload.
Do not change shared Icecast XSL files or restart other streaming instances.

See [Apache HTML link rewriting](https://httpd.apache.org/docs/2.4/mod/mod_proxy_html.html),
[scoped response substitution](https://httpd.apache.org/docs/2.4/mod/mod_substitute.html)
and [Icecast administration](https://icecast.org/docs/icecast-2.4.1/admin-interface.html).

## Maintaining the download tools and session

The running API loads `yt_dlp`, `js_runtime` and `cookies` from its private
`control/service.json` at startup. The bot INI settings are copied at initial
setup; later edits to the INI do not replace the API's own settings.
An isolated installation can use absolute paths, for example:

```json
{
  "yt_dlp": "/var/lib/mediabot-radio/tools/current/yt-dlp",
  "js_runtime": "node:/var/lib/mediabot-radio/tools/current/node",
  "cookies": "/var/lib/mediabot-radio/control/youtube.cookies.txt"
}
```

These are three fields within the existing private configuration, not a
replacement for the complete JSON file. Keep executable tools maintained and
readable by the API account; keep the cookie file owned by that account and
mode 0600. Never commit cookies, tokens or the private configuration.
Qualify a replacement downloader/runtime and session with one temporary MP3
and video identity check before activating them; then restart only the API
when it has no active jobs. Do not update tools automatically during requests.

A syntactically valid cookie export does not prove that YouTube accepts the
session. Follow the [official cookie export instructions](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies)
when authentication is needed. A paused downloader automatically becomes
eligible after its delay; an operator restart does not erase that delay.
A cookie refresh cannot guarantee lasting acceptance by YouTube.

For a failed request, start with its job ID and stable error code. A
`catalogue_failed` result never authorizes queue submission; a valid cached
file is retained for a later request. An `uncertain` result requires checking
the player before a new request. Keep existing MP3s and ledger entries during
updates; do not clear the queue or erase history as a repair step.

Audio validation references: [ffprobe input format](https://ffmpeg.org/ffprobe.html)
and [FFmpeg protocol allowlists](https://ffmpeg.org/ffmpeg-protocols.html).


## Request metadata

The HTTP service attaches catalogue `artist` and `title` to each validated
local MP3 request using Liquidsoap's `annotate:` protocol. This applies to new
`play` downloads, cached `play`, and catalogue `rplay`, including older MP3s
without embedded tags. Catalogue metadata takes precedence over existing tags.
Missing artists stay empty; a missing title falls back to the filename stem.
Controls are removed, values are bounded, and quotes, backslashes and Liquidsoap
interpolation markers are escaped as literal text.

Files, sidecars and their content fingerprints are unchanged. No re-download,
retagging, global metadata injection or change to the Liquidsoap configuration
is needed. Metadata follows the requested track when Liquidsoap actually plays
it. Queue acceptance still does not mean that a track has started: an active
live source retains priority. `song` continues to read the actual Icecast status.
Previously queued or currently playing requests keep their original metadata;
the corrected annotation applies to new requests after API restart.

See [Liquidsoap request metadata](https://www.liquidsoap.info/doc-2.3.3/metadata).
The deployed 2.3.2 parser is also covered by an isolated native resolution probe
in the operational package; it uses generated audio only, without a live queue.
