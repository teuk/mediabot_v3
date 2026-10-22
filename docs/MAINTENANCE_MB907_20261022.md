# MB907 — Keep RSS output recoverable when timers fail

Date: 2026-10-22. Development maintenance, no database schema change.

## Reproduced failures

Unpaced RSS output sends its first article and schedules the rest. If countdown
construction, loop registration or start fails, the prepared queue or duplicate
index can remain stuck. Later polls cannot re-enqueue those articles. A retained
old expiry callback can also remove the current timer and deliver another article
too early after a mode change or repeated expiry. Cleanup hooks can install a
successor while an old expiry or failed setup still owns local references.

## Change

Each native countdown has a private arm identity and cancelled/completed state.
Mode changes revoke that identity before stopping/removing the old timer.
Expiration revokes ownership before cleanup, cleans its own notifier, then checks
that cleanup has not installed another arm or queue before draining. Retained,
cancelled and duplicate callbacks do not drain or retire a successor. Callback
references to runtime, queue, loop and timer are weak, avoiding retained runtime
state when an old callback is kept externally.

A constructor/add/start failure drops only the affected prepared channel queue
and its duplicate-index entries, before cleanup can reenter. It stops/removes a
partially registered notifier and logs a bounded diagnostic. Unsent articles
have not been acknowledged in SQL; a later normal poll can prepare them again.
There is no immediate fallback burst or synchronous sleep. An inline expiry
that already completed, even if start then throws, preserves its result and
successor rather than reporting a contradictory setup failure.

The existing cancellable RSS countdown remains native. Shared IRC timer contracts
are not changed. The RSS drain/acknowledgement body, SQL, quotas/rotation, paced
mode without per-item timers, nominal order/spacing, formatting, fetchers, workers
and public APIs are unchanged. No Partyline, schema, migration, private config,
VERSION, service, test runner or audit change.

## Validation

Thirteen behavior assertions extend existing case 904; no numbered case is added.
They call the real runtime with a controlled repository/pacing collaborator and
captured output. There is no existing database, remote RSS, real IRC or public
listener. One scenario uses native IO::Async timers and checks three articles in
order with a separate minimum gap between each send. Other scenarios inject timer
constructor/add/start/cleanup failures, retain old callbacks, change modes, reenter
through cleanup, expire inline and verify object release and paced timer absence.

The new criteria pass **13/13 candidate** and **3/13 reference**. The three already
valid controls are native spacing, inline expiry and paced timer absence. The
others reproduce stuck state, stale/duplicate callbacks, cleanup ownership and
retained runtime issues. Recovery checks verify that unsent keys can be queued
again, that only accepted sends are acknowledged, and that queue/index agree.
The repository is a test collaborator; this is not a live SQL recovery rehearsal.

Twenty-four nominal vectors match the reference's output, acknowledgements and
queue/index state across one/two channels, multiple batch sizes and paced/unpaced
policies. Five mutations are detected: failed duplicate index retained, expired
timer slot retained, strong runtime capture, cleanup successor drained twice and
failed cleanup deleting its successor.

| Check | Local result |
| --- | --- |
| Runtime/fixture syntax | OK |
| RSS and IRC timer group, 29 files | 1,195/1,195, 3 s |
| Security / startup | GO, 37 invariants / OK |
| Full reference, 1,156 files | 30,396 passed + 1 failed / 30,397, 142 s |
| Full candidate, 1,156 files | 30,408 passed + 2 failed / 30,410, 141 s |

MB786's updater exit-status check fails in both full suites. MB647's observed
process-identity check also fails in the candidate. Their components and tests
are unchanged. A separate same-process comparison of both actual Doctor collectors
observes a live PID via kill 0 without a /proc entry, giving identical absent
owner facts. This supports a local visibility limitation; the failure sets are
not called identical and neither full suite is declared green. No speedup is
claimed. The delivered validator requires the complete unfiltered suite to pass
on the server, without MB786/MB647 exemptions. See QUALIFICATION.md for package
and installation/rollback evidence. These checks do not prove every regression
absent or guarantee notifier removal when the underlying loop refuses cleanup.
