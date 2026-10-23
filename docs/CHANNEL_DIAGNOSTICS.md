# Channel diagnostics — MB938

The private Partyline command `.diagnose #channel` gives one bounded overview
of persisted flags and observed IRC state. It is available to authenticated
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
lines. It goes only to the requesting connection. The `.diagnose` request is
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

## Read-only scope

Two bound SELECT statements read the selected channel and a fixed list of 22
flags from CHANNEL, CHANSET_LIST and CHANNEL_SET. The collector checks execute,
fetch errors and result bounds, finishes statements, and discards partial flag
results. A failed current DB owner is not bypassed with an old fallback handle.
No configuration secrets, keys, channel keys, raw SQL errors, conversation text,
provider calls or private URLs are returned.

There is no INSERT, UPDATE, DELETE, schema change, transaction boundary, cache
reload, module activation, IRC request or scheduled job. A caller-owned database
transaction retains its ownership. The collector does not probe quotas, provider
availability, last errors, loaded/source version convergence, RSS cadence or
RandomQuote scheduling. Those are later roadmap steps requiring their own
observations. Existing `.stat`, `!features`, routing and feature policies remain
unchanged.

## Reusable report

`Mediabot::Diagnostics::Channel->new(bot => $bot)->collect($channel)` returns a
new detached hash containing `version`, `channel`, `observed_at`, `database`,
`transport_connected`, `runtime_active`, `runtime_connected`, `channel_joined`,
`flags` and `notes`. `observed_at` is an epoch; the Partyline renderer displays
UTC. `version=1` identifies the report format.

The collector accepts validated character strings or strict UTF-8 bytes for
#channels up to 200 UTF-8 bytes, rejects controls and extra arguments, and uses
existing IRC::TextBudget byte measurement. Its report contains no bot, DBI,
runtime or callback objects. The Partyline adapter emits UTF-8 exactly once.
Future consumers must enforce their own actor/channel authorization before
collecting; MB938 does not expose an HTTP endpoint or change mbweb permissions.

The seven native regression groups run in a child interpreter. They exercise
DBI/SQLite without SQL translation, read-only authorizer enforcement, partial
fetch errors under both RaiseError modes, caller transaction ownership, real
runtime lifecycle transitions, authorization and native IO::Async Telnet/DCC
sockets with Unicode channel names and a second session checking privacy.
