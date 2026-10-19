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


## MB850 — Unicode fingerprints without changing existing RSS identity

Two hashing sites accepted character strings but passed them directly to
Digest::SHA, which consumes octets. Characters above U+00FF (curly punctuation,
non-Latin scripts, emojis) could therefore raise a wide-character exception.
This is distinct from the MB847 HTTP output correction: the bytes must be
selected before hashing, while original text remains unchanged for presentation.

### RSS IDs and deduplication

`rss_item_key` uses ID, GUID or URL, then title/date as a fallback. A numeric XML
entity can produce wide characters even when the HTTP document is all ASCII.
A wide GUID, Atom ID or fallback title could abort parsing and make a valid
feed look broken to the poller.

The internal digest helper now first tries lossless byte downgrading on a local
copy. Every input that Digest::SHA could already hash keeps exactly the same
bytes and SHA-256 key: ASCII, Latin-1, already encoded byte strings and their
UTF-8-upgraded Perl scalar equivalents. Only previously unhashable wide text is
encoded as UTF-8. This deliberately preserves legacy identity rather than
re-encoding every stored key. No Unicode normalization or key migration occurs.
Original item strings, key field precedence, cleaning/length bounds and field
separators remain unchanged.

`1246_mb850_rss_unicode_identity.t` fixes byte-for-byte legacy expectations,
checks wide values across all identity fields and fallback, and parses actual
RSS/Atom documents containing numeric Unicode entities. The actual poller uses
an isolated in-memory repository holding a previously announced Latin-1 item;
only the new Unicode item is inserted, repeated polls deduplicate it and the
old item remains suppressed. Initial polling still records a quiet baseline.
No external HTTP request or real database is used by this test.

### API v3 failure diagnostics

`FailureLedgerV3` had the same byte-boundary defect after sanitizing and bounding
an exception to 512 characters. The plugin manager contains errors from its
own observer, so a Unicode fingerprint failure silently lost that diagnostic
record rather than updating counts/history.

The bounded text now undergoes the same lossless downgrade / wide-only UTF-8
conversion before salting and hashing. Existing byte-sized fingerprints remain
unchanged for the same runtime salt. Raw exception text is still absent from
reports; only the short fingerprint, resource, runtime kind, counts and times
remain. Reference exceptions keep their generic fallback, and success still
clears the corresponding streak without erasing history. Cardinality/ring
bounds and instance-local lifetime remain unchanged.

`1247_mb850_unicode_plugin_failures.t` checks exact byte/wide fingerprints,
warning-free recording, counts, streak reset, bounded detached reports and
absence of raw text. It then runs Unicode exceptions through real API v3
command, event, job and HTTP-callback boundaries, verifies all four records and
normal recovery, and checks unload/reload clears the old instance history.
Local callback/scheduler fixtures provide IO; no live IRC or provider is used.

Only RSS.pm and Plugin/FailureLedgerV3.pm change in production. The accepted
MB849 DTC budget, scheduling, permissions, private configuration, persistent
state, SQL/schema and source transport are unchanged. Source installation backs
up its payload, requires focused/security/inventory/fast/full checks and restores
its own writes on required-check failure, preserving concurrent owner changes.
It stages/commits nothing and restarts no service.

After full host success, restart only the development bot and check ordinary
continuity. Do not reset feed history, inject broken plugins into production or
force announcements for acceptance. Commit through `commit.sh`, update production
normally and check nbot's `#i/o`. No web, dashboard, shortener or statistics
publisher deployment is required.


## MB851 — Hailo Unicode identities with existing brain continuity

Two Hailo identity paths passed character strings directly to Digest::SHA,
which consumes octets. A network/channel name or nick containing characters
above U+00FF could throw a wide-character exception. Brain selection would fail
for such a channel; nick placeholder construction could abort normalization or
rehydration even though the turn text and visible nick were otherwise valid.
This continues MB850's byte-boundary maintenance in Hailo's separate identities.

### Per-channel brain selection

`BrainRegistry::brain_id_for` now constructs its digest input in a local copy,
tries lossless byte downgrading, then encodes UTF-8 only if wide characters remain.
Every identity that could already be hashed retains its old bytes and exact
opaque `.brn` filename. This includes ASCII, Latin-1, pre-encoded byte strings
and upgraded byte-sized Perl scalars. There is no rehashing of existing brain
files, Unicode normalization, directory migration or history reset.

Existing network lowercasing and channel folding remain unchanged. The open
brain cache ceiling, LRU save-before-eviction, legacy seeding policy, private
permissions and factory interface also remain unchanged. The fix does not
change how any brain backend stores or learns text.

`1248_mb851_hailo_unicode_brains.t` verifies exact old IDs and paths with both
Perl scalar flags. Wide network/channel cases exercise the actual registry and
its factory boundary. A local file-backed fixture starts with pre-existing
learned bytes at the legacy filename, opens it, evicts it for a Unicode channel,
saves and reopens it in a fresh registry. The bytes and original path survive;
new and old channel objects remain separate, the cache ceiling holds, files stay
0600 and no seed/reset occurs. The fixture supplies brain storage; it does not
exercise the Hailo training algorithm or a real production brain database.

### Neutral nicknames and output restoration

`Normalizer::hailo_placeholder_for_nick` uses the same lossless downgrade /
wide-only UTF-8 conversion before hashing. The existing 32 neutral buckets,
opaque token format and learned mappings remain. Existing folding differences
between byte and character scalars are deliberately preserved; this correction
does not redefine IRC identity or negotiated CASEMAPPING.

`1249_mb851_hailo_unicode_nicks.t` freezes tokens observed on the intact MB850
base for ASCII, Latin-1 and pre-encoded nicks with both scalar flags. It then
runs wide identities through the real input normalizer and output rehydrator:
learnable text contains the neutral token, the exact visible nick stays in
transient turn metadata and is restored for output. Incoming command detection,
outgoing command refusal, invalid targets and NUL rejection remain effective.
No live IRC connection, external provider or production database is used.

The source-only security audit now recognizes the explicit octet preparation
inside `brain_id_for` as well as the original direct digest shape. It still
requires network/channel scope, symlink refusal and private umask. The brain
regression runs the real audit on a minimal public-code fixture and proves that
removing the network, channel, hash input, symlink or umask boundary is refused.
No audit invariant is disabled and no warn-only option is used.

Only Hailo/BrainRegistry.pm and Hailo/Normalizer.pm change in production runtime;
`tools/security_audit.pl` follows the equivalent scoped digest in source. No
SQL/schema, migration, private configuration, training policy, stored-format,
transport or scheduling change is required. Existing brains remain in place.
The source installer backs up its payload and requires focused/security/
inventory/fast/full checks. Failed required checks restore its own writes while
preserving concurrent owner changes. It stages/commits nothing and restarts no
service.

After full host success, restart the development bot and check ordinary
conversation/Hailo continuity on an already enabled test channel. Do not clear,
reseed, rename or retrain production brains for acceptance. Commit through
`commit.sh`, update production normally and check nbot's `#i/o`. No web,
shortener, dashboard or statistics publisher deployment is required.


## MB852 — Shared worker recovery when timer setup fails

The shared `AsyncWorker` foundation serves existing consumers such as source
fetches and provider/version/trivia workers. This round changes only that
foundation's exceptional timer paths; no consumer migration or new asynchronous
framework is introduced.

### Failed timer registration is rolled back

`_new_timer` previously returned its handle only after adding and starting the
notifier. If add/start threw after partial registration, callers had no handle
to remove. A failed initial deadline could therefore remain in the loop after
setup had reported failure and killed its child. The orphan timer retained the
worker graph; direct retained callbacks could still invoke their consumers.

Construction/add/start are now one protected arm. On exception the callback
slot is invalidated first, the provisional timer is stopped/removed, then the
original exception is rethrown. Callback indirection lives in a separate named
factory so its closure does not retain the whole setup activation under newer
Perl versions. A retained failed arm is inert even if cleanup itself cannot
remove a notifier. Successful timers retain their existing behavior and delay.

### Escalation remains effective without a grace timer

Termination previously swallowed failures while arming the KILL timer and the
finalization backstop. A child ignoring TERM could outlive the worker if its
KILL arm failed; if both arms failed, there was no remaining completion path.

A failed KILL arm now triggers immediate KILL for the still-owned, unreaped
child. A failed finalization arm triggers KILL before marking the result forced
and proceeding to terminal cleanup; otherwise cleanup would remove a working
KILL arm before it could run. The original `worker_timeout` or `worker_cancelled`
result remains authoritative. Normal grace delays and TERM/KILL behavior are
unchanged when arms succeed. An already-reaped child receives no signal.

The existing IO::Async process watcher continues to own reaping. There is no
blocking wait, detached process, manual post-ownership waitpid or synchronous
fallback. Consumer completion stays one-shot and frees its capacity even when
its backstop registration fails. Late callbacks and cancellation remain inert.

### Native regression coverage

`MB852WorkerFixture.pm` supplies a real IO::Async Poll loop with narrowly scoped
fault injection after native timer add/start. It tracks only children forked by
these tests, and signal interception never delivers TERM/KILL to a reaped PID.
A pipe handshake proves the child has installed TERM-ignore before escalation
is requested; a separate pipe releases it during safe baseline cleanup. Tests
use no IRC, external endpoint, provider, database or private configuration.

`1250_mb852_worker_timer_setup.t` checks rollback, original errors, stopped and
detached timers, inert retained callbacks and released context. Real worker
setup failure still yields exactly one structured timeout_timer error, its real
watcher reaps the killed child, no worker stream/timer remains, and the same loop
accepts a successor whose actual fork/pipe packet is preserved. IO::Async's own
SIGCHLD handle is distinct from worker-owned stream/timer resources.

`1251_mb852_worker_termination_timers.t` drives both timeout and explicit cancel
through KILL-arm failure, force-arm failure and both failures. TERM-resistant
children are escalated, reaped and completed once without waiting for a working
grace arm. Retained callbacks cannot repeat completion or signal old PIDs.
A real child is also reaped while pipe delivery is withheld, verifying that the
process/EOF barrier remains until timeout and that failed-arm recovery does not
signal an already-reaped process number.

Only AsyncWorker.pm changes in production. Normal worker protocol, byte/output
caps, child exception envelopes, process/EOF barrier and deadlines remain.
Accepted MB849 DTC display, MB850 fingerprints and MB851 Hailo identities are
preserved. No SQL/schema, migration, private configuration, stored format,
source selection, AI policy or web deployment change is required.

Source installation backs up the payload and requires focused/security/
inventory/fast/full checks. A required-check failure restores its own writes,
keeping concurrent owner edits/deletions. It stages/commits nothing and restarts
no service. After full host success, restart only the development bot and check
normal command/source/MetaAI continuity on an already enabled test channel.
Do not inject timer failures into production for acceptance. Commit through
`commit.sh`, update intended production instances normally and check nbot's
`#i/o`. No shortener, dashboard or statistics publisher deployment is required.


## MB853 — Periodic scheduler failure recovery

This continues lifecycle maintenance in the central scheduler's periodic path.
It does not add or enable tasks, change normal intervals or rewrite the calendar
scheduler repaired in MB839.

### Registration owns construction and loop attachment together

The scheduler publishes a task entry before constructing its periodic timer.
Previously a constructor exception left that task name registered with no timer,
blocking registration retries. An add exception removed the entry but did not
remove a notifier already attached to the loop. Unconditional deletion also
could erase a same-name replacement registered during loop-boundary reentry.

Construction, task/timer attachment and loop add now share one protected
registration. A failed original registration is removed only if it is still
the current object. Its provisional timer is stopped and removed, and its
original exception is rethrown. An independently registered same-name successor
keeps its own metadata, timer and callback. Existing weak callback ownership
still prevents a retained old timer from retaining or executing the old task.

### A failed start can be retried

A native periodic start can arm before throwing. Previously `start()` reset
its task flags but left the timer running. The task appeared stopped, its tick
was suppressed, and every new start failed because the timer was already
running. Explicit stop also returned early on the stopped task flag.

On a failure still belonging to the current task/generation, the scheduler
invalidates its lifecycle, resets started/next-run metadata and stops its partial
periodic arm before reporting failure. Manual registrations remain available
for a successful retry; failed autostart registrations retain their existing
rollback semantics. Calendar cleanup and newer task generations remain under
their existing ownership rules. Native stop/remove calls remain best effort
when cleaning an exceptional registration; successful operations are unchanged.

### Native regressions and fixture warning

`1252_mb853_scheduler_registration_recovery.t` uses actual IO::Async periodic
timers and injects constructor/add errors after native operations. It checks
exact error propagation, released task names, detached timers, weak-reference
release and callbacks that cannot execute a failed or replacement registration.
A reentrant loop add removes/re-adds the name before the old add throws; the
new running schedule survives, runs its own callback and remains removable.

`1253_mb853_scheduler_periodic_start.t` injects a transient error after real
start, checks stopped metadata/timers, then retries the same manual registration
or a fresh autostart registration. Actual zero-first-interval ticks run through
the real loop, update statistics once and retain ordinary stop/removal behavior.
Tests do not contact IRC, providers, network services or a real database.

The MB852 fixture's method override now scopes both `redefine` and `once`
warning categories explicitly. This removes the compile-only one-use symbol
notice observed on teuk.org; it changes no assertion or worker behavior.

Only Scheduler.pm changes in production. Accepted MB836/MB839 task ownership,
MB849 display, MB850/MB851 Unicode identities and MB852 worker recovery are
preserved. There is no SQL/schema, migration, private configuration, stored
format, enabled task, scheduling frequency or web deployment change.

Source installation backs up the payload and requires focused/security/
inventory/fast/full host checks. Required-check failure restores its own writes,
keeping concurrent owner edits/deletions. It stages/commits nothing and restarts
no service. After full host success, restart only the development instance and
check normal scheduled/source/command continuity; do not inject timer failures
into production for acceptance. Commit through `commit.sh`, update intended
production instances normally and check nbot's `#i/o`. No shortener, dashboard
or statistics publisher deployment is required.


## MB854 — Log rotation continuity and checked archive moves

This continues MB837's active-descriptor preservation at the automatic rotation
boundary. It does not alter the explicit `reopen_logfile` contract or configure
new log destinations.

### Stop after the first failed rename

The rotation loop previously ignored rename failures. If `.log.1` could not
move to `.log.2`, execution still promoted the base file to `.log.1`, overwriting
history that had failed to move. A failed base promotion was also silently
followed by reopening the same path.

Every existing archive/base rename is now checked. The first failed move aborts
further rotation steps with an explicit operation error. The active descriptor
remains usable, and a later size-check can retry after filesystem recovery.
Rotation of multiple files is not an atomic transaction: any older archives
already moved before a later failure remain at their new positions; there is
no speculative rename rollback. The fix prevents proceeding past the failed
move and overwriting the archive that could not be moved.

### Automatic errors do not discard the current message

Automatic rotation runs after stdout output but before file and console-hook
delivery. A rotation/open exception previously escaped log(), so the current
message missed its active file and Partyline console callbacks even though
MB837 kept the previous descriptor open.

`log()` now contains automatic rotation errors, then continues its normal file
write attempt and console dispatch. The existing descriptor is used until a
successful rotation replaces it. A fixed warning identifies rotation failure
without including the path, exception text or current message. It is emitted
once per failed rotation streak, and successful rotation resets suppression.
The warning callback itself is contained. There is no diagnostic for filtered
messages or a logger without a file.

The existing one-stat-per-100-writes throttle remains. This is not a new retry
loop or guarantee that an unwritable/full filesystem can accept data: writing
to the active descriptor remains best effort. Explicit initial-open and manual
reopen errors remain visible to their callers. Normal successful rotation still
writes the boundary record to the newly opened base file and closes the old
handle before subsequent records.

### Native filesystem regressions

`1254_mb854_log_rotation_continuity.t` renames the live file and places a real
directory at its path, inducing open failure even under root without permissions
or IO mocks. Unicode boundary records still reach the live descriptor and
console, diagnostics remain bounded/redacted, explicit reopen still fails,
filtered debug records remain suppressed, and recovery archives prior records
without duplicating the new boundary. A second failure after successful recovery
emits a new single diagnostic. Console-only logging remains effective.

`1255_mb854_log_archive_rename.t` uses real directory collisions at `.log.2`
and `.log.1` to fail older-archive and base-file promotion respectively. Failed
rotation preserves the current history and blocked archive; automatic logging
continues with one console delivery/diagnostic. Removing the collision allows
normal ordered rotation, retaining the old archive and keeping each boundary
record in the correct file. No real instance log is opened or moved.

Only Log.pm changes in production. Accepted MB130 rotation ordering, MB837
reopen continuity, MB852/MB853 timer recovery and other runtime safeguards stay
in place. No SQL/schema, migration, private configuration, stored format, log
level, retention count, schedule or web deployment change is required.

The source installer backs up its payload and requires focused/security/
inventory/fast/full host checks. Failed required checks restore its own writes,
preserving concurrent owner edits/deletions. It stages/commits nothing and
restarts no service. After full host success, restart only the development
instance and check ordinary command/source/log/console continuity. Do not force
filesystem failures or rotate production logs for acceptance. Commit through
`commit.sh`, update production normally and check nbot's `#i/o`. No dashboard,
shortener or statistics publisher deployment is required.
