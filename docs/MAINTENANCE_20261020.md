# Maintenance — 2026-10-20

## MB855 — Coherent Icecast status observations

### Reproduced defect

`get_primary_mount_status` fetched the Icecast status three times: global
server data, listener counts and selected mount information. `get_summary`
made a fourth request for the detailed mount list. A station transition
between requests could therefore combine the old server with new listener
counts, another title and a different detailed list. A second-request outage
could also discard the already received valid observation.

The intact MB854 implementation fails the new consistency and real loopback
HTTP regressions. These are controlled reproductions, not a claim that an
inconsistent production response was observed.

### Corrected behavior

Each public aggregate now fetches `status-json.xsl` once and derives its
global status, listener totals, selected mount and detailed mounts from that
one decoded response. Shared private normalization helpers retain the existing
public result shapes, raw status/selected-mount fields, numeric normalization,
Unicode strings, stable mount sorting and configured-primary/first-mount fallback.

There is no new cache: a later method call always makes a fresh request. The
scope is one Icecast response, not a transaction with the station or Liquidsoap.
Standalone status, mounts, listeners and now-playing calls remain independent
fresh observations. HTTP/empty/JSON/structure/no-mount failures remain explicit;
the next valid response can recover without a stale or partially cached result.

### Validation and rollout

Regressions exercise changing injected HTTP responses, a valid observation
followed by an outage, single-source HASH and multi-source ARRAY documents,
explicit zero listeners, Unicode metadata and failure/recovery. A real forked
loopback HTTP server changes the complete station document on every request,
covering the public aggregate and standalone methods through HTTP::Tiny and
the actual JSON decoder. Only test-owned sockets/children are created.

Only `Mediabot/Radio/Icecast.pm` changes in production runtime. Endpoint, HTTP
factory/TLS policy, timeout, command permissions, IRC presentation, metrics cache,
playback/queue control and private radio configuration remain unchanged. There
is no SQL/schema, persistent-format or service deployment change. MB849 DTC,
MB850/MB851 Unicode, MB852 workers, MB853 scheduling and MB854 logging remain.

The package requires focused, security, command-inventory, fast and full host
validation before retaining source writes. It stages and commits nothing and
restarts no service. After successful host checks, restart only the development
bot and check ordinary IRC continuity. If radio is configured there, inspect an
ordinary radio status/song response; otherwise qualify the deployed radio
instance during its normal update. No forced stream transition, outage,
filesystem failure, Icecast/Liquidsoap restart or web deployment is needed.

## MB856 — Inch syntax and finite conversion results

### Reproduced defects

The conversion handler removed every token equal to `in`, treating the inch
symbol as an optional English separator. Requests such as `!convert 12 in cm`
or `!convert 1 m in` therefore lost an actual unit and returned syntax help.

The numeric module also accepted overflowing scientific input as a successful
`Inf` result. Converting through a base-unit intermediate could overflow or
underflow even when the final result was representable: `1e300 TB` to `TB`
became infinity, and a subnormal milligram identity became zero. Temperature
formulas could likewise overflow before division despite a finite result.

### Corrected behavior

Only a fourth-argument form can contain a separator, and it is removed only
from the position between the source and destination units:

```text
!convert 12 in cm
!convert 12 in to cm
!convert 1 m in
!convert 1 m to in
!convert 1 m in in
```

The module accepts the existing signed decimal/scientific syntax using ASCII
numeric characters. References, trailing line breaks and Unicode digits that
Perl's numeric conversion cannot parse are refused without arithmetic warnings.
Converted input and final results must be finite. Overflow becomes a bounded
error rather than a public success. Unit scaling forms the fixed unit ratio
first, and temperature formulas multiply the ratio rather than multiplying
before division. Representable large/small conversions therefore remain usable.

This is still ordinary floating-point conversion, not arbitrary precision or
physical validation of temperatures. Existing underflow/rounding limits and
display precision remain. Aliases, unit families, negative values, optional
separators, different-family errors and unknown-unit errors are retained.

### Validation and rollout

The new arithmetic case covers large finite conversions, a subnormal identity,
input/output overflow, malformed/non-scalar/Unicode numeric input, ordinary
conversions in all six families and descriptive refusals. The handler case uses
the actual conversion function and Context with captured bot delivery; it covers
inch source/destination positions, separators, mixed case and aliases, channel
and private replies, finite large results, private error delivery, input limits
and exactly one success audit event only after a successful conversion.

Only Convert.pm and the conversion argument handling in DBCommands.pm change
in production. No SQL/schema, private setting, persistent format, provider,
rate-limit, command permission or web deployment change is involved. After
full host validation, restart the development bot and check ordinary `!convert`
requests on an enabled test channel. Commit through commit.sh before normal
production updates; no real stream, outage or external API probe is needed.

## MB857 — Event subscriptions revoked during dispatch

### Reproduced defect

Both EventBus dispatch methods snapshot the current listener list. An earlier
callback could remove a later listener with `off()`, or clear its subscriptions,
yet that later callback still ran from the retained snapshot. A nested event
could return to an outer event that continued invoking the revoked entries.

The integration regression loads the real ScriptDryRun plugin through
PluginManager, then replaces it from an earlier public-command event listener.
Normal replacement unregisters the old observer correctly, but the in-progress
event still called that observer afterward. Its observation counter increased
despite the unsubscribe. This is a controlled reproduction, not a claim that a
production reload or external script execution was observed.

### Corrected behavior

`off()` marks only an exact removed entry as revoked; event and global `clear()`
mark all entries they remove. The shared dispatch claim checks that marker before
calling a callback. No registry scan is added for each callback. Removing an old
handle cannot affect another registration with the same callback or metadata.

A callback already executing finishes normally. The fix prevents future calls
to revoked entries, including calls from existing snapshots; it does not cancel
work that a callback has already launched. Newly added listeners remain deferred
from the current snapshot, but are available to a subsequent or nested event.
One-shots are still claimed before execution, and old snapshot cleanup cannot
delete newly registered replacements. These rules apply to `emit()` and
`emit_report()`; revoked callbacks contribute neither execution counts nor errors.
Live callback exceptions remain isolated and reported normally.

### Validation and rollout

The core regression covers exact/copy/wrong-event handles, regular and one-shot
removal, nested emissions, event/global clearing, replacement registration,
clear counts and scope, later delivery and live exception isolation. The plugin
regression uses actual PluginManager load/replace and ScriptDryRun subscribe,
observe and unregister methods; a minimal local bot captures lifecycle state
without connecting to IRC or running any script.

Only `Mediabot/EventBus.pm` changes in production runtime. No SQL/schema,
private configuration, stored data, command permission, provider policy, network
request or service change is required. MB849 DTC display and MB850–MB856
maintenance remain intact. Full host validation is required before development
acceptance and commit through commit.sh. Check normal command/plugin continuity
after the development restart; there is no need to force a live plugin reload
mid-command or disturb production to reproduce this edge case.

## MB858 — News delivery timers and reentrant enqueue

### Reproduced defects

The parent news replay queue used an expiry callback that captured the queue
strongly and unconditionally deleted its current timer. Invoking an old expiry
again after its successor was armed removed that successor's ownership marker
and scheduled another timer. The real loop could retain two countdowns for one
queue; the queue could also stay alive through a retained completed callback.

Clearing a queue stopped/removed its timer before detaching the queue. An enqueue
from a cleanup hook consequently joined the old queue and was discarded when
cleanup finished. Separately, a helper that enqueued another news batch during
an immediate delivery could recursively drain the queue before the outer send
recorded its completion time, allowing a second line in the same interval.
These are controlled callback/loop reproductions; no production incident is
asserted.

### Corrected behavior

Each timer owns a distinct arm token. An expiry must claim that exact arm before
it can remove a timer or drain output. Repeated, cleared or superseded callbacks
become no-ops. The callback weakly references the bot and queue, so retaining a
completed or failed timer does not retain either queue state or transport state.
The active bot still owns a pending queue normally.

Cleanup invalidates the arm, empties and detaches its exact queue before calling
timer stop/remove. A replacement queue created by cleanup stays independent. If connection-change
cleanup enqueues fresh news, the outer enqueue joins that matching replacement
instead of overwriting it and orphaning its timer.
Constructor/add/start exceptions retain the bounded existing diagnostic and
clear only the failed owner's output. The partially registered timer is stopped
and removed, and a later request can recover normally.

A drain is serialized while a line passes through the usual delivery helpers.
Nested enqueue appends its whole batch within the existing capacity bound and
leaves delivery to that drain. The outer frame records the completed send time
and arms one successor if necessary. If delivery replaces the queue, the old
frame cannot arm another timer on its behalf.

The normal 1.5-second shared interval, idle-queue remainder, late-loop behavior,
FIFO destinations, queue capacity, TTL and connection/channel-generation checks
remain unchanged. Other asynchronous commands retain their existing replay path.
No immediate burst or blocking sleep is introduced as a fallback.

### Validation and rollout

The two new cases cover retained/duplicate callbacks before and after completion,
a new bulletin, connection replacement, queue lifetime, real IO::Async countdowns,
partial add/start failures, private-error redaction, recovery, cleanup reentry and
nested enqueue with each delivered interval checked. Existing news delivery,
context revocation and asynchronous worker tests remain part of qualification.
The new tests use local capture helpers and controlled clocks; they neither send
IRC messages nor call a news API.

Only Mediabot/CommandAsync.pm changes in production runtime. No SQL/schema,
private configuration, stored format, provider policy, web deployment or service
change is required. MB849 display and MB850–MB857 maintenance remain intact.
After full host validation, restart the development bot and check an ordinary
news request on an enabled test channel, then commit through commit.sh before
normal production updates. No forced timer fault is needed on a running bot.

## MB859 — Calculator numeric literal consistency

### Reproduced defect

SafeCalc's decimal/scientific tokenizer used Perl's Unicode-aware digit class.
That class accepted decimal characters which Perl's numeric conversion does not
interpret. The conversion warning was contained by the existing literal parser,
but the parser still accepted the converted numeric prefix (or zero).

For example, U+0661 followed by `+1` evaluated to 1 rather than refusing the
unsupported literal. `2e` followed by U+0662 evaluated to 2. Fractional and mixed
ASCII/Unicode digits were affected too. The actual calc Context handler returned
these values as successful results, recorded them in calculation history and
emitted successful calculation audit events. This is a controlled local
reproduction, not a claim about an observed user calculation on production.

### Corrected behavior

Every digit position in a decimal/scientific literal now uses the ASCII digits
accepted by numeric conversion. A Unicode digit anywhere in a literal causes
the entire expression to fail tokenization with the existing fixed
`Invalid characters in expression.` error. There is no partial calculation or
attempt to silently normalize unsupported characters.

The existing command handler already routes that syntax refusal privately.
It does not update calculation history or emit a success audit event. No change
to DBCommands or Context is needed. Ordinary ASCII numbers, decimal points,
signed exponents, hexadecimal literals, operators, precedence and supported
functions retain their behavior. Accepted whitespace, UTF-8 flagged ASCII
strings, the original typed expression and six-significant-digit formatting
remain usable. Length, arithmetic magnitude, exponent and parser-step bounds
and the prohibition on string eval remain intact.

### Validation and rollout

The pure regression exercises Arabic-Indic, extended Arabic-Indic, Devanagari,
fullwidth and mathematical digits in integer, mixed-integer, fractional,
leading-fraction and signed/unsigned exponent positions. Refusals emit no Perl
warning. Valid decimal/scientific and hexadecimal expressions, negative powers,
functions, Unicode whitespace and normal formatting remain covered.

The delivery case uses the real calc handler and Context with captured replies.
It seeds valid history, submits unsupported digits through public and private
contexts, and checks the caller-only syntax refusal, unchanged prior history,
absence of a success audit event and warning-free completion. Supported
calculations still use their normal destination, history and one success audit.
No new test connects to IRC, a database or an external API.

Only Mediabot/SafeCalc.pm changes in production runtime. No SQL/schema, private
configuration, stored format, permission, provider/research policy, web deployment
or native updater change is required. MB849–MB858 safeguards remain intact.
After full host validation, restart the development bot and check an ordinary
`!calc 2+2` request on an enabled test channel, then commit through commit.sh
before normal production updates.

## MB860 — Calendar timer construction and lifecycle recovery

### Reproduced defects

Calendar rearm created its IO::Async countdown outside the arm's error boundary.
The initial start wrapper contained construction failures, but construction of
the next occurrence from an expiry callback could throw out of that callback.
The task remained marked started with no owned timer or next occurrence. A
normal start then reported success without scheduling anything.

The existing weak timer reference was installed only after loop add succeeded.
An add failure before that point left a timer/callback reference cycle, even
after removal from the native loop. Reentry from construction, add or start
could also replace or restart a task while the old arm was being installed.
The old frame could report success, orphan an extra timer or clear/stop the
new lifecycle's timer when handling its own failure.

Expiry similarly removed its notifier before clearing ownership. A restart
from that cleanup boundary could establish a new timer which the old expiry
then erased, while still executing the superseded occurrence and counting it
as a tick. These are controlled native-boundary reproductions, not claims of
observed production outages or concurrent operator restarts.

### Corrected behavior

Construction, publication, add and start now share the calendar arm's checked
error path. A provisional notifier has a local strong owner and a weak callback
reference before entering native loop operations. The task identity, generation,
started state and exact timer ownership are checked across these boundaries.
If installation fails or is superseded, only that provisional notifier is
stopped/removed. Its ownership is detached before cleanup so cleanup reentry
cannot erase another timer. An ordinary failure leaves the existing registration
stopped with no next occurrence, available for explicit start/retry. A completed
occurrence remains counted even when its following rearm fails.

Expiry claims its exact current timer, clears ownership before native removal,
then rechecks the lifecycle before invoking the task and updating tick metadata.
A newer lifecycle survives the old expiry and owns its own future occurrence.
A callback already executing is not interrupted; existing post-callback identity
and generation checks still prevent the old callback from rearming a successor.

Calendar date resolution, integer delays, minimum one-second wait, interval
metadata and callback failure logging are unchanged. Periodic task setup/start
is not modified. There is no automatic immediate retry loop or catch-up burst.

### Validation and rollout

The recovery case injects constructor/add/start failures using real IO::Async
objects. It checks stopped metadata, failed notifier release, retained callback
inactivity and scheduler lifetime, explicit retry and removal. An actual native
expiry fails its next constructor, keeps an unrelated countdown responsive,
then executes a real later occurrence after retry with correct tick statistics.

The ownership case restarts the same object from constructor/add/start, with
both normal return and an old-frame exception. It also replaces the registration
under the same name and restarts from native expiry removal. New timer identity,
metadata, notifier counts, callback execution and final removal remain checked.
Existing calendar resolver, periodic ownership and timer failure regressions
are included in qualification. No new test connects to IRC, SQL or an API.

Only Mediabot/Scheduler.pm changes in production runtime. No SQL/schema, private
configuration, stored format, command permission, provider/research policy,
web deployment or native updater change is required. MB849–MB859 maintenance
remains intact. After full host validation, restart the development bot and
check normal IRC/scheduler continuity, then commit through commit.sh before
normal production updates. No fault injection is needed on a running bot.

## MB861 — Per-invocation plugin HTTP cache policy

### Reproduced defect

The shared v3 HTTP service included plugin, URL, Accept and body limit in its
cache key, but omitted the requested cache TTL. A successful response retained
for 60 seconds was therefore also returned to an invocation requesting zero
TTL, without starting a new worker. A shorter policy could inherit a response
older than its requested lifetime. Zero TTL prevented writes but not reads.

The integration reproduction loads the real short-content-v3 package through
PluginManager. Two channel policies use the same endpoint, one with TTL 60 and
one with TTL 0. The zero-TTL channel received the first channel's cached body.
Changing an already-warmed channel's policy to zero had the same effect. These
are controlled local reproductions, not observed production endpoint failures.

### Corrected behavior

The normalized TTL joins the existing plugin/URL/Accept/body-limit cache identity.
Positive policies retain independent entries and expiry times; an equivalent
explicit/default TTL still shares the same entry. The read path explicitly
requires a positive TTL, matching the existing positive-TTL-only write path.
Zero TTL performs no cache read or write and leaves other live entries intact.

The total process cache capacity remains 128 entries across all policies.
Per-plugin isolation, Accept/body-limit separation, expiry comparisons, cache-hit
metrics and success-only storage are unchanged. A zero-TTL request still passes
through the normal two-worker concurrency limit, origin circuit, HTTPS/DNS/body
validation and final generation/channel checks. It cannot force work through an
open circuit or deliver after plugin disable. No new option or activation rule
is introduced; the existing caller setting now applies consistently.

### Validation and rollout

The service regression warms a cache, switches among zero/short/long/default
TTLs, checks exact expiry boundaries and independent bodies, then exercises
plugin/Accept/body-limit isolation, bounded eviction, cache metrics, server
failure/circuit recovery, capacity refusal and cancellation. A real fork/pipe
worker reads controlled local response data before and after a body change,
showing that zero TTL obtains the new response despite a warm positive cache.

The integration regression uses the actual PluginManager, invocation policies,
HTTP service and short-content package. It verifies separate channel TTLs,
live policy editing, observe output suppression, off admission and disable/unload.
Only the existing offline bot/context fixture is reused; HTTP fetch is not
mocked at the plugin boundary. No new test contacts an external endpoint or IRC,
uses SQL or changes private configuration. Plugin storage uses a temporary local
data directory.

Only Mediabot/Plugin/HTTPServiceV3.pm changes in production runtime. The cache is
process-local; no persistent format, SQL/schema, permission, provider/research
policy, private configuration, native updater or web deployment change is
required. MB849–MB860 maintenance remains intact. After full host validation,
restart the development bot and check normal plugin/IRC continuity, then commit
through commit.sh before normal production updates. No live endpoint failure
or plugin activation change is needed for acceptance.

## MB862 — DTC source access after wire truncation

### Reproduced defect

The shared formatter considered source line count when deciding whether to
include the full-quote link. It separately clipped each colored IRC line to
430 UTF-8 bytes. A quote with one long dialogue therefore lost text but offered
no link to read the complete story. The same happened with up to ten source
lines, through manual dtc/bashfr random, ID and search requests and automatic
Spark announcements. This is a controlled local reproduction, not a new report
of a live source or transport failure.

### Corrected behavior

The formatter records byte clipping as well as source line omission. When a
known-ID quote loses text to the byte cap, its canonical link is appended if
there is room. If the batch is already at the configured maximum, its existing
last two positions become the omission marker and link. The normal ten-message
quote cap therefore still allows eight dialogue messages before those two
positions; a shorter clipped quote uses only the messages it needs. The visible
automatic command and manual search heading stay separate as before.

Quotes already requiring a line-count link keep exactly one link, in the same
position. Complete short quotes retain their original presentation and acquire
no unnecessary URL. A missing/invalid ID remains visibly unknown without an
invented destination. Existing bounded max_lines overrides remain respected.

The wire fitter encodes each long line once, takes the allowed byte prefix
including space for the ellipsis/reset, and decodes the prefix while discarding
an incomplete final character. This replaces repeated whole-line encoding for
each removed character. Formatted lines remain at most 430 UTF-8 bytes, with
whole international characters, the original prefix and a final color reset.

### Validation and rollout

The formatter regression covers exact first-line byte boundaries, later-line
clipping, one- through four-byte characters, first/last clipped dialogue,
three/five/ten-message limits and overflow, link identity/uniqueness, unknown
IDs, empty input and byte-for-byte unchanged complete quotes. New cases retain
the existing MB849 ten-line presentation tests rather than changing them.

The delivery regression runs the actual Spark sender and all six manual
alias/mode combinations through real CommandAsync fork/pipe completion. It
compares the quote bytes between automatic and manual paths for short and full
batches. Channel loss after the first manual dialogue blocks the final URL;
automatic transport refusal still stops delivery and consumes the normal
cooldown. Only external source IO and final IRC transport are replaced. There
is no external HTTP, IRC, SQL or private configuration access in the new cases.

Only Mediabot/DTC/Format.pm changes in production runtime. Permissions, pacing,
AntiFlood, fetch ownership and source limits, the native updater, private state,
provider/research policy and SQL/schema remain unchanged. No configuration,
schema or web deployment is required. MB849–MB861 maintenance remains covered.
After complete host validation, restart the development bot for normal DTC/IRC
acceptance, then commit through commit.sh before normal production updates.

## MB863 — Exact YouTube identity across metadata readers

### Reproduced defects

The URL router and two metadata readers independently extracted video IDs.
Their watch expressions searched greedily beyond the outer query: a v= inside
another parameter's nested URL, or inside a fragment, could replace the actual
watch selector. The bot then requested/displayed a different video's metadata,
or read that other video's warm cache entry. The same expressions accepted
paths merely beginning with watch. Path forms such as youtu.be also accepted
the first eleven characters of an overlong ID and announced an unrelated prefix
video. These are controlled offline reproductions, not reported API incidents.

### Corrected behavior

The public metadata reader, radio metadata reader and URL router now use the
same existing selector function. Watch URLs require the exact supported watch
path and one complete v parameter in the outer query, before the fragment.
Nested parameter contents and fragments cannot supply another selector.
Duplicate selectors, including equal duplicates, are refused as ambiguous.

Shorts, live, embed and short-link paths require a complete eleven-character
identity, with an optional trailing slash and ordinary query/fragment suffixes.
Overlong IDs, extra path segments, unsupported hosts, nested outer URLs and
ASCII control/space-bearing URLs select no video. ID case remains significant.
Metadata readers use the router's existing supported host families; no new host
or URL form is introduced. Existing direct helpers expect the URL itself, not
surrounding IRC text; the ordinary dispatcher still extracts it from a message.

A refused identity reaches neither the video metadata cache nor the Data API
or its oEmbed fallback through these readers. Generic URL-title routing remains
subject to its own existing rules. Valid equivalent URL forms retain shared
video caching, current caller/channel decoration, duration and view formatting,
verified HTTP policy, API limits and the existing empty-items oEmbed fallback.
No permission, API key, endpoint, TTL or source publication policy changes.

### Validation and rollout

The URL case covers every existing supported host family, watch query ordering,
Shorts/live/embed/short-link forms, fragments and nested values, exact ID case,
trailing slashes, duplicate selectors, overlong/short IDs, wrong paths, host
impostors, controls, malformed and non-scalar input.

The integration case runs the actual public/radio readers and URL dispatcher.
It checks the selected ID in the API request and visible title, a competing
warm cache, equivalent URL reuse across callers/channels, refused identities
before HTTP/cache output, +Youtube admission and ordinary anti-repeat. An empty
API items result reaches oEmbed with the same canonical watch identity and
retains an international title. A real AsyncWorker fork/pipe carries the actual
reader result. Only HTTP IO and final output are replaced; no external API,
IRC or SQL connection is used. Existing routing/format tests remain unchanged.

Only Mediabot/External/YouTube.pm changes in production runtime. No SQL/schema,
private configuration, persistent format, MetaAI research policy, native updater
or web deployment change is required. MB849–MB862 maintenance remains covered.
After complete host validation, restart the development bot for normal URL/IRC
acceptance, then commit through commit.sh before normal production updates.
