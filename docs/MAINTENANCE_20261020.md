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
