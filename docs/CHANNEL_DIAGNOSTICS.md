# Channel diagnostics — MB938 / MB939

The private Partyline command `.diagnose #channel` gives one bounded overview
of persisted flags, observed IRC state, RSS/RandomQuote pacing and two expected
instance scheduler tasks. It is available to authenticated
Master and Owner sessions. `.help diagnose` finds the command.

```text
.diagnose #test
```

For example, with +AppleMusicFallback, -AppleMusic, +Reddit and -UrlTitle:

```text
Channel diagnosis #test (read-only)
Database: fresh; observed <UTC timestamp>
IRC: transport=yes; runtime_active=yes; runtime_connected=yes; joined=yes
Links: UrlTitle=off Youtube=off YoutubeSearch=missing AppleMusic=off AppleMusicFallback=on Reddit=on
...
Note: AppleMusicFallback is configured on, but its AppleMusic preview prerequisite is off.
```

The ellipsis abbreviates the remaining groups here; the actual command includes
conversation, AI, community and output flags. The report contains at most 13
lines in MB938, or 17 with the four MB939 activity lines. It goes only to the
requesting connection. The `.diagnose` request is
not announced to other Partyline sessions; it remains in the requester's usual
private command history. Ordinary command rate limits still apply.

## How to read it

| Observation | Meaning |
| --- | --- |
| `on` | The chanset is registered and has a CHANNEL_SET row for this channel |
| `off` | The chanset is registered and has no CHANNEL_SET row for this channel |
| `missing` | The chanset is absent from CHANSET_LIST; no effective default is inferred |
| `unknown` | The component or a reliable observation is unavailable |
| `Database: fresh` | The scoped channel and flag queries completed without a fetch error |
| `Database: channel_not_found` | The channel lookup completed but returned no registered channel |
| `Database: unavailable` | No usable database handle was obtained from its current owner |
| `Database: error` | A prepare, execute, fetch or result-validation error prevented a complete flag observation |

Persisted `on` is not a provider-health or delivery result. Runtime caches may
lag behind a direct SQL change. No cache is flushed by this command, and the
feature's own live authorization remains authoritative. Missing catalogue rows
may have feature-specific defaults; the diagnostic deliberately reports the
absence itself. In particular, `Games=missing` is not a claim that games are off.

IRC transport connectivity is read through `is_connected`. Runtime activity,
connection state and JOIN state come from the existing ConversationRuntimeState
snapshot. A configured Channel object alone does not prove a current JOIN.
Missing runtime support remains unknown; contradictory connection observations
are displayed with an explicit note. SQL errors do not suppress an independent
runtime observation, and a runtime error does not prevent a database read.
These are observations taken during the request, not an atomic cross-system
snapshot or a promise that the connection remains unchanged afterward.

The link note documents current routing: Reddit and Youtube have independent
flags; generic URLs, Spotify, Instagram, Facebook and X use UrlTitle. Apple Music
uses AppleMusic; its optional extra Spotify/YouTube matches additionally require
AppleMusicFallback. The diagnostic describes these relationships and does not
replace or change any runtime feature gate.

## RSS, RandomQuote and scheduled tasks

MB939 adds four lines, for example:

```text
RSS: runtime=present; state=fresh; source=channel; gap=5min; daily=2; reserved_24h=1; wait=300s; file_mtime=<UTC timestamp>
RandomQuote: runtime=present; state=fresh; source=channel; interval=900s; custom=1; next_attempt=<UTC timestamp>; wait=900s; pending_ticket=0; file_mtime=<UTC timestamp>
Task(instance) rss_poll_dispatch: state=present; started=yes; interval=15s; ticks=4; last_tick=<UTC timestamp>; next_wakeup=<UTC timestamp>; overdue=0s
Task(instance) randomquote_dispatch: state=absent
```

The collector uses the loaded runtimes' explicit `diagnostic_status` methods.
It does not create substitute runtimes or infer activation from a stored file.
A RandomQuote flag can be off while an old attempt remains recorded. The JOIN,
persisted flag and pacing observations are deliberately separate.

| Observation | Interpretation |
| --- | --- |
| `runtime=absent; state=unknown` | No runtime object was available to observe |
| `state=fresh` | The existing document was read and validated during this request |
| `state=absent; source=default` | Neither state nor lock existed; defaults are observed without creating either |
| `source=default` on a fresh document | The document has no policy row for this channel |
| `state=busy` | An existing exclusive lock prevented a nonblocking shared read |
| `state=invalid` | Bounded JSON or the component's schema validation failed |
| `state=unavailable` | Access, unsafe path, incomplete state/lock pair or component observation failed |
| `reason=...` | A fixed reason code; never a raw exception or filesystem path |
| `file_mtime` | Modification time of the entire state document; unknown if absent |

RSS `gap` is in minutes, `daily` is a rolling 24-hour limit (zero disables that
constraint), and `reserved_24h` counts stored reservations, including attempts
whose later IRC write might fail. `wait` comes from the existing pacing policy.
It does not measure pending articles, provider quota or successful deliveries.

RandomQuote uses the runtime's validated default interval and the state's own
custom override. With no channel row, `next_attempt=unscheduled`; a default
interval alone is not an observed deadline. A pending ticket is persisted
attempt state, not proof of an active worker. `next_attempt` is eligibility for
an attempt, not an exact send time: flags, JOIN, task wakeups and selection still
apply. The diagnostic neither claims nor consumes the ticket or quota.

Only `rss_poll_dispatch` and `randomquote_dispatch` are queried via `task_info`.
They belong to the instance, not to an individual channel. A missing scheduler
is unknown; a scheduler with no matching registration reports absent. A present
task can be stopped. `last_tick=never` means no callback entry was recorded.
Ticks are callback starts, including failures or no-op callbacks, not successes.
The next wakeup is not the next article/quote deadline. A positive `overdue`
describes the observed clock difference; it does not diagnose a root cause.

Fresh is read freshness, not business freshness. `file_mtime` can reflect another
channel's update. These fields reveal no last successful delivery, last error,
article URL, quote text, other channel's settings or private configuration.

## Read-only scope

Two bound SELECT statements read the selected channel and a fixed list of 22
flags from CHANNEL, CHANSET_LIST and CHANNEL_SET. The collector checks execute,
fetch errors and result bounds, finishes statements, and discards partial flag
results. A failed current DB owner is not bypassed with an old fallback handle.
No configuration secrets, keys, channel keys, raw SQL errors, conversation text,
provider calls or private URLs are returned.

There is no INSERT, UPDATE, DELETE, schema change, transaction boundary, cache
reload, module activation, IRC request or scheduled job. A caller-owned database
transaction retains its ownership. MB939 additionally reads at most two existing
state documents, each limited to 262,144 bytes, under their existing shared
nonblocking locks. Lock and state handles are read-only; symlinks and special
files are refused. No directory, file or lock is created, repaired, chmodded or
rewritten. A held writer lock returns busy immediately. A shared reader briefly
participates in the existing lock protocol; it does not bypass concurrent writers.

The component validators and status calculations are reused. Historical
decision-making `status` methods keep their existing behavior and are not used
by this diagnostic. No task is started, stopped or ticked, no RSS reservation or
RandomQuote ticket is changed. The collector still does not probe provider
availability, last errors or loaded/source version convergence. Those are later
roadmap steps. Existing `.stat`, `!features`, routing and feature policies remain
unchanged.

## Reusable report

`Mediabot::Diagnostics::Channel->new(bot => $bot)->collect($channel)` returns a
new detached hash containing `version`, `channel`, `observed_at`, `database`,
`transport_connected`, `runtime_active`, `runtime_connected`, `channel_joined`,
`flags`, `activity` and `notes`. `observed_at` is an epoch; timestamps render in
UTC. `version=2` adds `activity` to the MB938 format. This detached hash contains
`rss`, `randomquote` and `tasks`, with whitelisted scalar observations. No object,
callback, raw document or arbitrary task name is included. Failures of one
component do not suppress independent observations.

The collector accepts validated character strings or strict UTF-8 bytes for
#channels up to 200 UTF-8 bytes, rejects controls and extra arguments, and uses
existing IRC::TextBudget byte measurement. Its report contains no bot, DBI,
runtime or callback objects. The Partyline adapter emits UTF-8 exactly once.
Future consumers must enforce their own actor/channel authorization before
collecting; MB938 does not expose an HTTP endpoint or change mbweb permissions.

Thirteen native regression groups run in a child interpreter. The original seven exercise
DBI/SQLite without SQL translation, read-only authorizer enforcement, partial
fetch errors under both RaiseError modes, caller transaction ownership, real
runtime lifecycle transitions, authorization and native IO::Async Telnet/DCC
sockets with Unicode channel names and a second session checking privacy.
Six more groups exercise absent/default state, scoped real policies, pending
tickets, rolling quotas, lock contention, invalid/oversized documents, incomplete
pairs, symlinks and FIFOs, plus native scheduler lifecycle and extended wire
output. State bytes, modes, inodes and mtimes are compared around observation.
