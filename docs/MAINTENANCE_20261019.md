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
