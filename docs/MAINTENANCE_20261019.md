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
