# Channel diagnostics — MB938 to MB940

`.diagnose #channel` is a private Partyline overview for authenticated Master
and Owner sessions. `.help diagnose` finds it. The request is not announced
to other sessions; it remains in the requester's normal private history.
Normal rate limits apply. The UTF-8 reply has at most 24 lines, including
five plugin rows and explicit omissions.

## Configuration and runtime

The common model reads the selected CHANNEL identity and 22 fixed chansets
with two parameterized SELECTs, checks prepare/execute/fetch failures and
finishes statements. A failed current DB owner is not bypassed with an old
handle. Partial flag results are discarded. No cache or transaction boundary
is changed. Caller-owned transactions retain ownership.

| Value | Evidence |
| --- | --- |
| on | Registered chanset with a CHANNEL_SET row for this channel |
| off | Registered chanset without a CHANNEL_SET row |
| missing | No CHANSET_LIST entry; no effective default is inferred |
| unknown | No reliable observation |
| Database fresh | Complete scoped channel and flag read |
| channel_not_found | Successful channel lookup with no matching row |
| unavailable / error | No usable handle or failed observation |

On is not proof of provider availability or delivery. Runtime caches may lag.
A configured Channel object is not JOIN evidence. Transport connectivity and
ConversationRuntimeState supply independent connection/activity/JOIN states;
contradictions remain visible. SQL failure does not hide an independent JOIN.
The report is an observation during the request, not an atomic cross-system snapshot.

AppleMusicFallback requires AppleMusic previews. Reddit, MixCloud and Youtube have their
own flags; UrlTitle covers generic URLs, Spotify, Instagram, Facebook and X.
These explanations do not replace any feature gate. Games missing, for example,
is not a claim that games are effectively off.

## Pacing and scheduled work

Loaded RSS/RandomQuote runtimes expose `diagnostic_status`. No replacement
runtime is created. Their `observe` methods reuse native validators and status
calculations through a shared read-only reader, bounded to 262,144 bytes.
It opens only existing regular files, refuses symlinks, takes an existing
shared nonblocking lock and creates, repairs, chmods or rewrites nothing.
A held writer lock returns busy immediately. The brief shared read participates
in the existing lock protocol. Historical decision-making status methods keep
their behavior and are not called by the diagnostic.

State is fresh, absent, busy, invalid or unavailable; a missing runtime stays
unknown. Fixed reason codes replace raw exceptions and paths. Fresh means read
and validated now, not recent business activity. File mtime concerns the whole
document, possibly changed by another channel.

- RSS gap is minutes, daily is a rolling 24-hour constraint, zero disables that
  constraint, and used/reserved_24h counts reservations, including attempts
  whose later IRC write failed. Wait is the native policy delay.
- RandomQuote shows the runtime's effective default or channel override,
  stored next attempt and pending ticket. With no channel row it is unscheduled;
  a known default interval does not invent a deadline. Pending is not proof of
  an active worker. Flags, JOIN, task wakeup and selection still govern delivery.
- Only rss_poll_dispatch and randomquote_dispatch are inspected via task_info.
  They belong to the instance. Missing scheduler is unknown; missing registration
  is absent. Started, ticks, last tick, next wakeup and overdue are observations.
  Ticks count callback entries, including exceptions and no-ops, not successes.
  MB940 adds callback_exceptions and last_exception for contained exceptions
  since registration. No message is retained, and an old registration or
  generation cannot charge a replacement. These do not cover timer setup/rearm
  failures or a callback returning false. Observation invokes no callback.

## Retained failure and plugin evidence

A third bound SELECT reads only COUNT and MAX(last_error_at) from RSS_FEED
for the channel id. No label, URL or last_error text is selected. Successful
polls clear those fields; zero means none retained, not no historical failure.
The timestamp is labelled database time; no UTC conversion is invented.
Failure of this query leaves other observations available.

PluginManager::channel_diagnostic_snapshot observes at most 64 loaded API v3
entries. It neither discovers nor loads packages and never creates a ledger
or service. ChannelPolicyV3::observation_for returns mode/configured without
copying config. The existing core explanation supplies blocked/shadow/active
decisions. Missing grants and matching quarantines are separate evidence.
V1/v2 channel policy remains unknown.

Only existing bounded per-instance ledgers are read. Failure and quarantine
records match the canonical channel name, ignoring letter case but never merging
punctuation aliases that may have distinct database identities. Native policy
normalization remains unchanged. Empty-channel overflow
buckets and other channels are excluded. At most three kind/timestamp pairs
per plugin are retained in this report; no message, fingerprint, resource or
config value appears. Eviction, unload and restart remove evidence. Failure
counts never create or release quarantine. Five rows appear in Partyline,
with explicit omissions; the detached report carries at most 64.

## Optional local publication and mbweb

The canonical source supplies `/channels/:id/diagnostics` and
`/api/channels/:id/diagnostics`, linked from channel detail. Both require a
fresh login, the existing userHasChannelAccess check and a current database
identity before any file read. Revoked users/membership and authorization
outages cannot reuse stale access. Responses are Cache-Control: no-store.

The web projection includes only that channel's flags, JOIN, pacing, retained
RSS summary and loaded v3 entries configured there or with retained failures
there. Global loaded counts, scheduler details, raw errors and other channel
history are omitted. Every rendered value is escaped. The exact current
channel name, numeric id, report version, strict UTF-8 and byte bound are checked.
Observations older than 120 seconds are hidden; more than five seconds in the
future is invalid. Freshness uses observed_at, not file mtime. Missing/invalid
publication means unavailable; no web request calls a provider, shell or bot action.

Publication is off by default. After creating a bot-owned directory without
group/world write permission (e.g. 0750), an operator may explicitly set under
`[main]` in the separately managed bot configuration:

```ini
CHANNEL_DIAGNOSTICS_DIR=/home/mediabot/mediabot_v3/run/channel-diagnostics
CHANNEL_DIAGNOSTICS_CHANNELS=#test
```

At most eight distinct #channels, separated by spaces, are accepted. The
optional scheduler task observes one per five-second tick, a full rotation
within 40 seconds. It holds a weak bot reference. A fresh valid report is
atomically replaced as <id>.json, mode 0640, at most 65,536 bytes. Unsafe paths
and symlink/special destinations are refused. Failed collection leaves the
previous file to age out; contained setup/publication failures do not stop the bot.
These files are observations, not business state. `.diagnose` never publishes.

In the separately managed mbweb environment, MBWEB_CHANNEL_DIAGNOSTICS_DIR
may point to that same instance-specific directory. There is no fallback.
The asynchronous reader opens only a numeric-id regular file, read-only and
nonblocking, refuses symlinks and enforces the byte bound during reading.

This lot changes canonical source, not /opt/mbweb/app. It does not edit private
configuration, create the directory, enable publication, restart either service
or deploy the web app. Follow the established deployment/development pilot
procedure in docs/MBWEB_3.5.md; avoid a live-to-source sync overwriting this new
source before deployment. Source changed does not mean runtime loaded.

## Report and evidence

The detached report format is version 3. It retains version 2 fields and adds
channel_id when found, rss_failures and plugins. No bot, DBI, callback, raw
document, conversation, credential or private URL is returned. Consumers must
enforce actor/channel rights before collecting or reading it. Unrecorded errors,
provider health and loaded/source version convergence remain unobserved.

Nineteen native groups in the existing Partyline case cover DBI/SQLite and
read-only authorizer, transaction ownership, errors under both RaiseError modes,
runtime lifecycle, filesystem locks/bytes/modes/inodes/mtime, native scheduler,
loaded plugins/retention/reload, optional publication and a Perl-to-Node contract
check, plus real local Telnet/DCC sockets with UTF-8 and another session proving
privacy. Existing Node files cover authorization, native file bounds/freshness,
identity mismatch, symlinks and escaped HTML. No remote service is probed.
