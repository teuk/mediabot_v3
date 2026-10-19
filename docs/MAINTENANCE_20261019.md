# Maintenance — 2026-10-19

## MB844 — RSS recovery and channel lifecycle identities

Reviewed base: the supplied `snap_mediabot_v3_teuk_20261019_090843.zip`,
VERSION `3.6dev-20261019_065548`, including the accepted MB843 research policy.
The defects below were reproduced offline against that source; this does not
assert that either caused a production incident.

| Trigger | Previous behavior | Corrected behavior |
| --- | --- | --- |
| RSS worker start throws or refuses | The feed reservation and channel barrier can remain occupied | One failure completion releases the attempt; a later poll can run |
| RSS completes during launch | A completed returned handle can be stored again | Store a handle only while its attempt is still pending |
| An old RSS completion fires after a replacement starts | It can delete the new slot and consume an obsolete article | Only the current attempt can finish, exactly once |
| RFC1459 JOIN and PART use equivalent bracket, backslash or caret spellings | Lowercasing alone can leave the original joined generation authorized | The negotiated identity fold revokes the same room |
| The server uses ASCII or strict RFC1459 | An unconditional RFC1459 fold would merge distinct names | Honor the actual CASEMAPPING value |

### RSS attempt ownership

The RSS adapter reserves a unique attempt before calling the launcher. Its one
terminal callback checks ownership and releases the slot, channel barrier and
handle before invoking downstream processing. This permits a consumer to start a
successor safely. Duplicate completion, inline completion followed by refusal or
exception, and exceptions from result handling cannot reclaim that successor.
Launch failures use bounded public error codes/text rather than a raw exception.

The shared process worker is unchanged. RSS retains its worker ceiling, timeout,
output bound, child-side isolated database connection, silent first baseline,
source checks, output pacing, channel quota, feed rotation, delivery revalidation
and acknowledgement. Existing runtime error recording still uses the existing
repository; no new query or persistent format is introduced. This adds no retry
loop or synchronous network fallback.

### Negotiated channel identity and delayed replies

Conversation lifecycle state receives CASEMAPPING from the existing numeric 005
handler, independently of Fullop parsing. ASCII only lowercases; strict RFC1459
also equates brackets/braces and backslash/pipe; RFC1459 additionally equates
caret/tilde. Before negotiation and after disconnect, comparison is conservatively
ASCII. Unsupported/malformed values do not change the accepted mapping; explicit
removal returns to ASCII.

A change rekeys remembered channel state and gives each joined room a new
monotonic generation. Pending replies captured under old rules become obsolete,
while current membership remains usable for new requests. Merging aliases keeps
the actual joined spelling; narrowing never invents an additional joined room.
Repeated identical announcements preserve tickets. Disconnect/shutdown still
invalidate membership and reconnect never reuses an earlier authorization token.

This concerns the shared conversation runtime membership/generation gate used by
late output checks. It is not a rewrite of every nickname/channel normalizer in
the project. MetaAI native chansets, provider selection, research routing, source
labels, shorturls, memory, limits and existing final delivery checks are retained.

### Verification and activation

Two new regression files cover injected failures/reentry, real local AsyncWorker
setup failure and fork/pipe completion, negotiated identities, mapping changes,
reconnection, the actual numeric 005 handler and actual delayed CommandAsync
output after an equivalent departure/rejoin. Their fixtures do not contact IRC,
external providers or a production database. Existing RSS, conversation, Fullop,
worker and MetaAI regression cases are included in the package's targeted lane.
The package README records qualification results and any local environment limits.

Installation changes source only. It requires the reviewed clean `master`, makes
a private source backup and runs targeted, fast and full host checks before
reporting success. A failed check restores its own source writes while retaining
concurrent edits. Private configuration and the real Git index are untouched.

After host validation, restart only the development bot for ordinary acceptance:
a normal addressed reply on an already enabled channel and routine enabled RSS
polling are sufficient. Do not provoke failures or change live channel membership
to test this patch. Commit with `commit.sh`, then update production normally and
check normal continuity on nbot's `#i/o`. No database schema/data initialization,
private configuration, web deployment or publisher restart is required.


## MB845 — Automatic quote ownership and plugin event batches

Reviewed base: `snap_mediabot_v3_teuk_20261019_111925.zip`, VERSION
`3.6dev-20261019_091519`, including the host-validated MB844 source.
Both defects below are reproduced offline against the intact snapshot. The
initial regression runs fail 15/72 quote assertions and 22/43 event assertions;
this does not assert either failure was observed in production.

| Trigger | Previous behavior | Corrected behavior |
| --- | --- | --- |
| RandomQuote completes inline before start returns | A completed handle can be retained again | Store the handle only while the attempt is pending |
| An old quote callback fires after a successor starts | It can clear the successor's reservation and worker handle | Only the current attempt can finish, once |
| Quote completion starts another attempt, then the old launcher throws/refuses | Old failure cleanup can remove the successor reservation | Release the old attempt before the consumer and preserve its successor |
| A plugin clears its event queue and enqueues fresh work from its event/error handler | The old active batch can process fresh work immediately | Stop the old generation and schedule a fresh bounded batch |
| A defer operation completes inline, arms a successor, then throws | Its error can clear the successor's scheduled flag | Scheduling failure cleans up only the arm it owns |

### Automatic quotes

RandomQuote reserves a unique attempt per case-normalized channel. One terminal
callback checks that ownership and removes its reservation and handle before
calling the existing result processor. A native setup error, injected refusal or
constructor exception follows the same completion path. Constructor exception
text is not logged. Consumer exceptions cannot retain the attempt or escape the
callback. A direct overlapping launch is refused; the normal tick still permits
at most two pending workers.

The persistent schedule/revision protocol and all SQL queries are unchanged.
The initial full-interval wait, no immediate retry/catch-up after failure, final
RandomQuote/JOIN/revision checks, channel selection, anonymous quotes, Unicode
wire bound and no-defer output remain authoritative. Only accepted transport
output updates the last sent id. Automatic selection still leaves quote recall
counters unchanged. No new configuration or data initialization is necessary.

### Deferred plugin events

EventQueueV3 claims a scheduled callback before dispatch. A retained callback
from a failed scheduling operation cannot drain queued work. The active drain
also records its generation and stops when clear() changes it, including when
called from dispatch or on_error. Fresh work retains its own deferred batch.
The real plugin manager already clears this queue on disable/unregister; its
normal disable/re-enable path now respects that active-batch boundary too.

A scheduling exception is still reported to its caller. If an inline callback
already scheduled a successor, the old exception leaves the successor's flag
alone. Pending/batch bounds, drop-newest overflow, processed/drop counters,
handler error isolation, policy/capability checks and owned scheduler jobs are
unchanged. No new retry or plugin activation is introduced.

### Verification and rollout

Two new regression files include real local IO::Async scheduling, a native
AsyncWorker setup failure, real fork/pipe selection through an isolated SQLite
fixture and the actual plugin manager's event handler disable/re-enable path.
They make no IRC connection or provider request and access no production DB.
Existing RandomQuote, API v3 lifecycle/policy/quarantine, quote services,
asynchronous command, RSS and negotiated-channel tests remain in the targeted
lane. The package README records the observed local qualification and any
container limits. Full host validation remains mandatory before commit.

Install source on teuk.org as mediabot, using the reviewed clean master/index
and private source backup. After host checks, restart only the development bot
for ordinary acceptance; observe an already enabled quote channel at its normal
cadence. Live failure injection, enabling plugins or shortening production quote
intervals is unnecessary. Commit through commit.sh, update instances normally
and check regular nbot continuity on `#i/o`. No schema/data migration, private
configuration, dashboard or publisher deployment is required.


## MB846 — MetaAI paced delivery and channel recovery

Reviewed base: the host-validated MB845 payload applied to
`snap_mediabot_v3_teuk_20261019_111925.zip`, with VERSION updated to
`3.6dev-20261019_113132` as shown in the supplied successful `1da2e18` commit.
The installer checks all reviewed source bytes and requires clean tracked state
and an empty index; it does not assume a remote checkout matches this base.

The defects were reproduced offline. Replaying a retained paced callback could
send an undefined or premature line and call the delivery terminal callback more
than once. That callback commits history and releases the channel job, so replay
after another question starts could corrupt its reservation. Separately, a
scheduler refusal left delivery with no terminal result; a thrown scheduling
exception could be swallowed by the upstream asynchronous provider boundary,
leaving the channel busy. Neither reproduction asserts an observed live incident.

| Trigger | Corrected result |
| --- | --- |
| The same paced callback is invoked twice | Its arm advances output only once |
| Old callback runs while sources await their own timer | Sources remain paced |
| Old callback runs after a new question starts | No duplicate output, history commit or job release |
| Scheduler refuses or throws before advancing the arm | Delivery aborts and releases its channel |
| Native timer is added but setup fails | Stop/remove that partial timer and abort once |
| Scheduler runs the callback inline, then refuses or throws | Preserve the successor arm or completed result |
| Final rights check fails or throws | Stop remaining lines and do not record an incomplete answer |

The public response still has up to two answer lines followed by the validated
sources line. Original-site labels remain dark grey, verified private shorturls
remain blue and underlined, every line retains the 400-byte envelope and public
transport uses `no_defer`. The configured pacing delay is unchanged. There is no
immediate fallback burst when scheduling fails. Source selection, research
routing, provider requests, budgets and +MetaAI permissions are unchanged.

A delivery consumes its arm before entering caller code. Terminal completion
invalidates the pending arm and breaks the recursive pump reference before
calling the existing consumer. Retained arm and native expiry callbacks are
constructed in separate helper scopes, so they do not retain the pump's lexical
activation after it has finished. A failed older scheduling frame checks arm
ownership before aborting, so it cannot cancel an inline successor. Failed native
timer setup is cleaned up locally. Retained callbacks after completion cannot
retain the runtime through the delivery pump. Existing bounded
`META_AI delivery_aborted` logging reports the outcome without raw exception text.

`1239_mb846_meta_delivery_arms.t` covers repeated/retained callbacks, scheduler
refusal/exception, inline completion and successor ownership, revocation, guard
and output failures, empty/single-line delivery, resource release, real countdown
execution and partial native timer setup failures. `1240_mb846_meta_delivery_recovery.t`
uses native +MetaAI policy reads against an isolated SQLite fixture, deterministic
contributor/evidence responses, verified-alias presentation and the real private
memory writer. It checks complete history, next-question recovery, source order,
revocation/re-enable and private local output. No external service or live
production database is contacted by these tests.

Installation changes one production module, this log, the changelog and two new
regression cases. It creates a private source backup, runs the focused safety
lane, then mandatory fast and full host validation. On failure it restores its
own changes while retaining concurrent edits. It leaves configuration, SQL/schema,
existing persistent state, the real Git index and running services untouched.

After successful host validation, restart only the development bot and use an
ordinary addressed question on an already enabled channel. Check answer/source
ordering and that a subsequent question is accepted normally. Do not inject
failures or replay callbacks on a live bot. Commit through `commit.sh`, update
production normally and check continuity on nbot's `#i/o`. No migration,
registration, private setting, dashboard or publisher deployment is required.


### MB846 R2 — Perl 5.40 callback lifetime correction

The R1 preview on teuk.org failed assertions 8, 13 and 18 of the new delivery-arm
case before installing any source. R1 had passed these assertions under local
Perl 5.38.2. Re-running the exact R1 test under an independently built Perl 5.40.3
reproduces precisely those three failures. The original assertions are retained.

An anonymous callback created inside the pump can keep the outer pump activation
alive after the recursive `$pump` variable is cleared. The activation retains the
runtime. R2 constructs arm callbacks and native expiry callbacks in separate
package helper scopes. They capture only the state references or timer ownership
needed for their task; clearing the pump on terminal completion now actually
releases its runtime. Pending delivery still owns its runtime until completion.

The expanded 78-assertion arm test passes under both Perl 5.38.2 and 5.40.3,
including retained native expiries after completion, setup refusal and timer
start failure. Tests explicitly confirm the requested native failure path was
reached and its actual expiry callback was retained. This also corrects the R1
test's unsupported timer getter, which could otherwise masquerade as a requested
setup failure. All three host-reported weak-reference assertions keep their
original conditions. The 51 integrated policy/history/private-output assertions
remain unchanged. Source installation still targets the clean MB845 base: the
failed R1 preview installed nothing and needs no rollback or service restart.


## MB847 — Metrics numeric safety and radio HTTP encoding

Reviewed base: `snap_mediabot_v3_teuk_20261019_141514.zip`, VERSION
`3.6dev-20261019_121430`, supplied after successful MB846 commit `190d709`.
The installer requires the exact reviewed source bytes, clean tracked state,
master branch, matching origin and an empty Git index.

Two defects are reproduced offline against that intact snapshot. Radio status
JSON is already serialized to UTF-8 bytes; the common HTTP builder encoded those
bytes again, corrupting international titles such as `Björk — Jóga`. Separately,
the numeric validator accepted scientific input such as `1e999`, which becomes
infinite when converted. Scalar setters accepted raw strings/references, and
scalar operations could replace or numerically coerce histogram state. A later
observation could then throw through the caller. These are code reproductions,
not a claim that a particular live instance encountered them.

| Trigger | Corrected behavior |
| --- | --- |
| Radio provider returns accented, non-Latin or emoji metadata | JSON bytes are transmitted once, preserving the original values |
| Plain text contains an unflagged Latin-1 character | The character body is still encoded to UTF-8 normally |
| Scientific input overflows to infinity | Refuse it before adding a metric sample or bucket bound |
| set/add/inc targets a histogram | Refuse scalar mutation and preserve the histogram |
| Two finite values would overflow the stored sum | Refuse the whole update before changing buckets or count |
| Bad instrumentation precedes an HTTP scrape | Keep the previous valid measurements and serve the scrape normally |

`_http_response_bytes` retains its character-body default and accepts an explicit
encoded-byte flag for the internal JSON route. It does not guess from Perl's
UTF-8 flag: valid character strings containing only Latin-1 may be unflagged.
The direct `render_radio_status_json` API continues to return encoded JSON bytes.
Its keys, status codes and media type are unchanged. Content-Length always uses
the bytes actually transmitted. Existing radio error behavior is outside this
change.

Metric grammar retains finite decimal and exponent notation. POSIX `isfinite`
checks the converted value and each resulting sum. Invalid values are silent
no-ops returning false; the last valid value remains available. Unsupported
scalar operations cannot corrupt histogram hashes. Sum validation precedes
bucket/count mutation, so overflow cannot publish a partial observation. Custom
finite positive bucket normalization and the default boundaries stay unchanged.
The explicit `le="+Inf"` bucket remains required and continues to count all
accepted observations; it is distinct from an infinite stored sample value.

Compatibility is deliberate: disabled/unknown metrics remain inert, undefined
set/add values still normalize to zero, finite negative gauge deltas and generic
histogram observations remain supported, counter resets via set remain possible,
and small scientific Time::HiRes durations still work. The existing five-second
render cache, metric names, routes, listener binding, request-header limit and
provider call pattern are unchanged. No cardinality or public API expansion is
introduced beyond the internal HTTP builder's explicit encoded-body argument.

`1241_mb847_metrics_numeric_contract.t` covers invalid/coercible values, mutation
types, atomic scalar/histogram overflow, recovery, bucket limits and legacy
numeric behavior. `1242_mb847_metrics_http_utf8.t` covers Latin-1, non-Latin,
emoji and nested metadata, direct JSON API compatibility, unflagged plain text,
Prometheus labels and exact byte lengths. Real IO::Async/loopback requests prove
that radio JSON and a later metrics scrape remain usable after rejected
instrumentation. Test listeners bind OS-assigned ephemeral loopback ports.
No production service or external provider is contacted.

Only Metrics.pm, the changelog, this log and two regression cases change.
Installation backs up source and requires focused, security, inventory, fast
and full host validation. Failure restores its own source writes while retaining
concurrent edits/deletions. Private configuration, persistent history, SQL/schema,
running services and the real Git index remain untouched by source installation.

After host checks pass, restart only the development bot. Check ordinary bot
continuity and the existing local metrics/radio endpoint if enabled; do not
change a live song or inject bad samples. Commit through `commit.sh`, update the
intended production instances normally, and check continuity on nbot's `#i/o`.
No dashboard, web, shortener or network-stats publisher deployment is required.


## MB848 — VDM completion resources and launch recovery

The VDM source boundary supports concurrent numbered-article jobs and coalesces
callers asking for the same article or feed. The manual `!vdm` and automatic
Spark paths then recheck delivery conditions before output. This pass preserves
that architecture and repairs two reproduced lifecycle failures.

### Reproduced failures

`AsyncFetcher::_finish` removed the active job from its map but left waiters and
the worker handle inside the completed job. A retained worker callback still
captured that job: former caller contexts remained reachable, and the job's
worker reference could complete a worker/callback/job cycle. When completion
ran inline and its caller immediately requested the same source again, the old
launch frame could also reattach its returned handle to its already-completed
job simply because the source key existed again.

Both `Runtime::request_manual` and `request_spark` reserved their channel before
calling the fetcher without an exception boundary. A fetch exception escaped
and left that reservation occupied. Subsequent requests then reported busy
instead of reaching the source. A fetcher completing inline and then reporting
failure could also produce a misleading manual failure notice after a successful
story. No production API or IRC connection is needed to reproduce these cases.

### Corrected ownership and compatibility

The source completion removes its waiter list and worker handle before calling
consumers. It delivers a local snapshot of the waiters, isolating each consumer
exception as before. Only the exact job still registered under that source key
may accept a returned handle. Duplicate terminal callbacks remain inert and a
new same-source request retains its own cancellable worker.

Both runtime entry points now contain fetch exceptions and consume one terminal
outcome per request. Refusal/exception without completion invalidates the old
callback and releases that request's reservation. Manual commands keep their
handled return value and bounded private unavailability notice; Spark keeps its
refused return value and stays quiet. No exception detail is logged or sent.
If a callback already completed inline, subsequent launch failure does not
repeat terminal processing, send a contradictory notice or disturb a reentrant
successor. A later callback from a failed launch cannot revive output.

| Contract | Retained behavior |
| --- | --- |
| Source identity | Feed and each numbered article remain separate; identical requests coalesce |
| Capacity | Four independent workers; configured global waiter bound; coalescing at full worker capacity |
| Cancellation | Current worker handles remain available; completed handles are not restored |
| Final delivery | VDM/Spark flags, connection, membership and activity checks run at completion |
| Repeat history | Only accepted delivery records a story; failed/revoked work records nothing |
| Return values | Manual request handled; Spark refuses on failed launch; source launch return contract unchanged |
| Privacy | Bounded existing notices/log codes; no raw constructor exception text |

### Regression validation and rollout

`1243_mb848_vdm_fetch_completion.t` covers retained contexts and completed-worker
cycles with weak references; inline launch/reentry with a same-source successor;
correct cancellation; duplicate callbacks; coalesced consumer exceptions; launch
refusal/exception; waiter/worker bounds; and a real worker passing an exact article
ID through its fork/pipe transport. It explicitly tests that an inline returned
handle cannot recreate a completed-job cycle while a successor exists.

`1244_mb848_vdm_launch_recovery.t` covers manual and Spark launch failure,
immediate recovery, silent late callbacks, one terminal notice, inline
completion/reentry followed by refusal or exception, and revoked successor work.
An integrated real Runtime/AsyncFetcher/AsyncWorker test coalesces two channels'
feed requests, revokes one before completion and delivers only to the other.
The new tests use local child values and isolated loops; no source HTTP, live
IRC, provider API, private configuration or database operation is performed.

Only the two VDM modules, changelog, this maintenance log and two regression
cases change. Existing MB844–MB847 safeguards remain covered. Source installation
requires focused, security, inventory, fast and full host checks. It backs up
source, restores its own writes on failure, preserves concurrent owner edits and
leaves the real index, private configuration and running services unchanged.
No SQL/schema, migration or persistent-format change is required.

After successful host checks, restart only the development bot and check ordinary
continuity. If VDM is already enabled on a test channel, exercise the normal
manual command and ensure it completes once and permits a following request;
do not enable automatic announcements solely for acceptance. Commit through
`commit.sh`, update production normally and check nbot's `#i/o`. No dashboard,
shortener, web or network-stats publisher deployment is required.


## MB849 — A useful DTC excerpt for automatic and manual requests

A live automatic `!dtc` showed only the first dialogue line, `...`, then the
full-quote link. Spark explicitly passed `max_lines => 3` to DTC's formatter,
whose truncation logic reserves two of those three lines for ellipsis and URL.
The manual formatter already allowed ten lines, so the separate Spark budget
was the cause. No source-fetch truncation or shortener failure was involved.

Spark now calls the same formatter with its shared default budget and accepts
up to that formatter's limit. It adds its visible command as before. Manual
`!dtc`, `!dtc <id>`, text search and the `!bashfr` alias retain the same response
budget through their real asynchronous worker path.

| Nonempty source lines | Quote displayed after the automatic command, or as the manual reply |
| --- | --- |
| 1–10 | All dialogue lines; no unnecessary ellipsis or link |
| More than 10 | First eight dialogue lines, `...`, canonical full-quote URL |

A manual search retains its separate result heading before the quote. Existing
colors, per-line byte guard, normal PRIVMSG/NoColors/AntiFlood path and bounded
deferred queue remain. This is a display-budget change, not a new scheduling
system: output still follows the instance's existing AntiFlood configuration.
Spark's audience/activity/permission checks, independent two-minute send limit,
forty-minute source-event cooldown, anti-repeat and delivery accounting remain.
VDM and other Spark event budgets do not change.

`1245_mb849_dtc_shared_display.t` checks 1/3/9/10/11/20-line boundaries and exact
truncation order. It drives actual manual dispatch and CommandAsync fork/pipe/
parent replay for both aliases with random, ID and search requests. Source IO
and final transport are local fixtures; the test proves the real worker starts
and does not recut the response. It also checks partial transport refusal and
retry throttling. Existing MB806 regression expectations now use a genuinely
long quote with the shared limit; focused checks retain AntiFlood and MB840/
MB841/MB848 lifecycle coverage.

Only Spark::Sender.pm changes in production. No private configuration, SQL/schema,
manual command routing, source fetcher, stored format or external API changes.
Source installation backs up the six changed/new files, runs focused/security/
inventory/fast/full checks and restores its own writes on required-check failure.
It leaves the index and running services unchanged. After host success, restart
the development bot and exercise manual `!dtc`, `!dtc <id>` and `!bashfr <id>`
on an already-enabled test channel. Commit via `commit.sh`, update production
normally, then check automatic/manual continuity on nbot's `#i/o`.
