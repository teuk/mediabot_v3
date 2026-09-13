# Radio requests

On a channel with **`+Radio`**, every participant can use:

```text
m play https://www.youtube.com/watch?v=VIDEO_ID
m play Michael Jackson Billie Jean
m rplay Radiohead
m rplay Idioteque
m radioqueue
m queue
```

`play` accepts an artist/title search or one HTTPS YouTube video URL. Text
search ranks at most five YouTube results by artist/title relevance. It prefers
official video/audio and artist Topic/VEVO hints when available. Covers, karaoke,
tutorials, reactions, remixes and speed/loop edits are rejected unless requested
explicitly. Accents and ordinary spelling mistakes are tolerated; view counts
are not a requirement. Missing titles and weak matches are refused. It excludes known live/upcoming videos and entries with
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
uses one compact channel line, with bracketed accents inspired by `song`,
when the shared public spacing permits; otherwise the same confirmation is sent by NOTICE.
“Added to the queue” means Liquidsoap
returned a request ID; it does **not** mean that playback has already started.
`play` and `rplay` never request a skip. Live priority
and track interruption follow the existing Liquidsoap configuration. In
particular, `track_sensitive=false` between playlist and queue can interrupt
the playlist when a request becomes ready. Qualify this policy separately
before promising that the current track will always finish.

## Withdraw an unwanted track

Authenticated **Master+** accounts on `+Radio` can use `m deltrack 28` (or
`!deltrack 28`). The number is **`id_mp3` in the central radio catalogue**, not
an ID from the IRC instance's local database. Administrator alone cannot do it.
New addition confirmations show `MP3 #<id>` so moderators can identify the row.
The withdrawal response is always a private NOTICE identifying the track.

The central service archives the original row in private SQLite `removed_tracks`
before deleting that exact row from MariaDB `MP3`. Its ID, YouTube video ID and
file path are then blocked for future API `play`/`rplay`, including cache reuse,
other configured instances and service restarts. Requests for another video ID
are a different identity: this cannot recognize every re-upload of a recording.
A busy download/push returns a brief retry message without deleting anything.

This command does **not** unlink the MP3, flush the queue, or skip on air.
Already accepted playout continues; use Administrator+ `nextsong` to skip it.
This preserves active file handles and independent playlist references. A
playlist directly managed outside this API is not filtered by this catalogue
withdrawal. No track is withdrawn automatically during installation.

If SQL fails, the archived withdrawal intent and block remain. Repeating
`deltrack` with the same central ID safely finishes it, including a lost SQL
acknowledgement. A concurrently edited row is left intact and requires operator
review. The archive is retained beyond ordinary request-history expiry; recovery
is an explicit operator task. Keep it in state backups. Do not roll the API back
to a version unaware of withdrawals once any have been recorded.

Selection is based on search metadata, not listening to or certifying an audio
recording. A misleading title may still pass. Use a precise YouTube URL for a
specific version; explicit URLs bypass version preferences, but never a Master
withdrawal. Existing catalogue contents are not bulk edited or deleted.

## See what is waiting

| Command on `+Radio` | Result |
| --- | --- |
| `m song` | Current Icecast title and listening URL, as before. |
| `m radioqueue` | One compact line: Icecast current title, first three waiting requests, remaining count. Public at most once per minute per channel; NOTICE otherwise. |
| `m queue` | Alias for `m radioqueue` on `+Radio`, with the same permissions and cooldown. |
| `m deltrack <id_mp3>` | **Authenticated Master+ only**: withdraw and block that central track, with private feedback. |
| `m nextsong` | **Authenticated Administrator+ only**: skip the selected track, then announce the confirmed new title and its queue/global-playlist origin. |

`song`, `queue` and `radioqueue` work for every participant through the same authenticated
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

Radio confirmations use a red (04) bracketed marker, bold artist/title in the
client's normal text colour, and an underlined YouTube replay link. Queue views
use a red `ON AIR` marker and orange (07) brackets around waiting positions. Position numbers and pending
titles use normal client text. No background, dark-grey body text or dark-blue link colour
is forced, so the content follows the reader's light/dark theme. IRC palettes
remain client-configurable. `song` itself is unchanged.

Each addition or queue response is one line, bounded to **360 UTF-8 bytes**
including formatting. Long labels are shortened; the replay URL remains intact.
For example, without the IRC formatting codes (duration and ID illustrative):

```text
[ + QUEUE #1 ] Stevie Wonder - Superstition · 4:01 · MP3 #37 · https://youtu.be/ftdZ363R9kQ
[ ON AIR ] Stevie Wonder - Superstition › [ 1 ] Paul Simon - You Can Call Me Al
```

The replay URL comes from the selected central catalogue video's exact ID,
for both `play` and `rplay`, never from the original free-text search. Duration
comes from the MP3 audio validation already performed before submission.
The optional `youtube_url` and `duration_seconds` response fields are stored
with that job in private SQLite `job_details`, so polling/restarts preserve
them. There is no extra YouTube lookup, audio probe, catalogue update or MP3
retagging for presentation. Missing/invalid IDs or unavailable measurements
are omitted; historic jobs without details still return a useful confirmation.
Details appear only after a confirmed push. An uncertain submission never
becomes a public success because it has metadata.

Clients need the updated display code to render these fields; earlier HTTP
clients keep working. No new configuration key is needed. The queue preview
stays compact and carries no extra replay URLs or automatic messages.

### Channel output budget

- `queue` and `radioqueue` share one public view per **60 seconds per channel**,
  across all callers. Further eligible reads use the same compact view by NOTICE.
- Confirmed additions and public queue views share a **15-second public gap**.
  A suppressed public success still reaches its requester by NOTICE.
- A confirmed `nextsong` transition shares that public gap; NOTICE otherwise.
  Preparation, errors and refusals are always private.
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
never presented as an empty queue. The following section describes the separate
administrative `nextsong` operation.

## Adaptive requests and Administrator+ nextsong

Successful `play` and `rplay` requests share a load-based cooldown. Pressure is
waiting Liquidsoap tracks plus downloads being prepared or transferred, across
all authenticated instances. The currently playing track is not waiting.

| Pressure | Same caller | Same channel |
| --- | --- | --- |
| 0 | 5 s | 5 s |
| 1 | 15 s | 5 s |
| 2 | 30 s | 10 s |
| 3 | 45 s | 15 s |
| 4 | 60 s | 20 s |
| 5 or more | 90 s | 30 s |

These delays are measured from acceptance of the previous request, not from
download completion. One bounded player count is shared for up to two seconds;
unavailable counts retain the conservative 120 s caller / 15 s channel policy.
A pending request still blocks another request by the same caller. Failed or
uncertain operations retain 120 s, except an empty search (5 s). Six waiting
tracks remain the physical queue limit. Searching, duplicate suppression and
YouTube pauses are unchanged. The central update changes this policy for all
existing HTTP clients without changing their configuration.

`nextsong` is an actual skip, available only to an authenticated Administrator,
Master or Owner on `+Radio`. All other callers are refused before HTTP. It uses
`POST /v1/next` and the same instance token; the service trusts each installed
bot's account authorization, never a role supplied in the HTTP body. Keep
instance tokens private. Skips share a global 15 s gap. A durable receipt is
written before sending the control command; retrying its ID or restarting the
API cannot send it twice. An uncertain outcome is reported privately.

The Liquidsoap controller must wrap **the final three-source fallback** used
by this radio's output. It compares a boot/track generation, executes at the
streaming frame boundary and skips only the selected source. It confirms the
subsequent track or replayed playlist metadata before announcing, for example:

```text
[ Next · queue ] Artist - Song
[ Next · global playlist ] Artist - Song
```

It refuses a selected live input. A track that changed naturally before the
command executes invalidates the old generation instead of skipping again.
The wrapper preserves live > queue > playlist priority and existing playback
behavior, including resuming an interrupted playlist. Missing metadata is
shown as unavailable, never guessed from a filename or a waiting request.

For a single-host install, copy `contrib/liquidsoap/mediabot-next.liq` to a
location readable by the Liquidsoap service (for example
`/etc/liquidsoap/mediabot-next-8000.liq`, root:liquidsoap 0640). Before the output:

```liquidsoap
full = fallback(track_sensitive=false, [live, queue, global_playlist])
%include "/etc/liquidsoap/mediabot-next-8000.liq"
full = mediabot_next_control(full, live, queue)
# The existing output.icecast must consume full.
```

Match these variable names to the actual configuration. Qualify the wrapper
with Liquidsoap 2.3.x and an isolated player before loading it in the service.
The control socket stays on loopback; remote clients continue using HTTPS.
This requires one controlled restart of that Liquidsoap process. Wait for the
request queue to empty and for any live input to disconnect. Icecast and other
radio instances need no restart. Until the controller is present, `nextsong`
returns an explicit unavailable notice; ordinary requests still work. Update
IRC clients through the normal publication/update flow for the new command.

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
- `POST /v1/next`: authorized bot request to advance the selected source;
  idempotent durable receipt, global skip throttle, no download.
- `GET /v1/health`: authenticated liveness check; no playback or download.
- `GET /v1/queue`: shared pending music labels and aggregate preparation counts;
  authenticated and read-only. Player reads share a four-second deadline and a
  single observation lock; submissions retain their independent ledger lock.
- One download/processing worker; six pending/working jobs globally, at most
  one per caller. Successful requests use the adaptive cooldown below.
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
- The additional tables (`download_pause`, `track_claims`, `queue_receipts`, `job_details`) live only in
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

### Why `nextsong` does not blindly send `request_queue.skip`

On this three-source selector, `nextsong` advances the selected source in its
streaming clock. When the request queue is on air, this has the queue-skip
behavior. When the global playlist is on air, skipping an empty request queue
would not advance the playlist and can leave a deferred skip for a later
request; the playlist must be advanced through the selected-source controller. The controller never sends a
second independent skip and refuses live input or a stale track generation.

| Selected source | Confirmed result |
| --- | --- |
| Queue, another ready item | Next queue item, in order. |
| Queue, last ready item | Return to the interrupted global playlist track. |
| Global playlist | Next available playlist track. |
| Live input | Refusal; no skip. |
| No available source or controller | Refusal; no invented title. |
| Track changes during the request | Stale request refused; no second skip. |
| Lost acknowledgement or API restart | Uncertain receipt retained; no automatic resend. |

A bad/unready queued request may be rejected by Liquidsoap and fallback may
resume the playlist; announcements use the actual observed source and title,
not a promised queue position. The isolated 2.3.2 probe also checks direct
`request_queue.skip` and confirms it does not advance an unrelated playlist.
Client code must be published and updated before remote `nextsong`/`deltrack`
use these handlers. Central-only installation cannot change an old IRC handler.
