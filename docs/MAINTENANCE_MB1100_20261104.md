# MB1100 — Keep explicitly refused reminders pending

## Fault

Reminder delivery claimed each selected row (`delivered = 1`) before calling
`botPrivmsg`. That prevents concurrent readers or a crash from sending a claimed
row twice. The sender, however, can explicitly refuse a message before any wire
attempt: a badword matches, or the bounded AntiFlood queue is already full.
The old code ignored this refusal, permanently consumed the reminder and even
created the next daily/weekly occurrence.

## Change

Keep the pre-send claim and its positive affected-row check. Inspect the normal
output acceptance result. Only after an explicit false/undefined result, release
the claim through a conditional UPDATE of that exact reminder ID, channel,
sender, recipient, original stored message and claimed state. The original
message and scheduling tags remain unchanged. Skip recurrence creation for the
refused occurrence; it may be retried when the recipient next speaks.

Both the original claim and the new release compare `HEX(message) = HEX(?)`.
This keeps snapshot matching exact even under MariaDB's case-insensitive message
collation: a case-only edit is a new snapshot, not permission to claim/reset the
changed reminder. The primary-key predicate still selects a single row.

A concurrent committed cancellation, body change, move or deletion cannot be
reset by the release. SQL failures and unknown affected-row counts produce a
bounded operational diagnostic without exposing the raw DBI error or reminder
body. Cleanup is best effort after the outcome is captured.

Accepted immediate or deferred output stays claimed. A transport exception is
allowed to propagate and also leaves the claim intact: transmission may have
started, so replay could duplicate a reminder. The existing twenty-row scan,
three-due-reminder budget, due checks, formatting, Unicode, public target and
local-calendar recurrence rules remain in place.

## Native tests and consolidation

Extend the existing MB961 fixture, with two real SQLite connections, RaiseError
on/off, and the actual Sender/AntiFlood queue. Only IRC effects and policy inputs
are captured. A NOCASE message column exposes case-only snapshot races while
HEX still compares the original UTF-8 bytes.

Four grouped checks exercise:

- Twelve real refusal/recovery cycles: badword/full queue, plain/daily/weekly
  messages, both DBI error modes. No wire/history or next recurrence on refusal;
  the row keeps its original tags pending. Recovery accepts it once and leaves
  the other channel alone; a recurring next occurrence is then created once.
- One queued acceptance at the thirty-item boundary, followed by actual queue
  draining: the reminder stays claimed and appears exactly once after the
  ordinary items, without being reinserted on a second reminder scan.
- Transport exceptions before/after a captured wire attempt: preserve the
  original exception and the claim, and never retry it on the next scan.
- Fourteen SQL/race controls: prepare/execute failures, cancellation, changed
  body, case-only edits, deletion and a stale case-only snapshot before claim.
  Failed release statements finish where available, with bounded diagnostics.

Keep the native MB926 two-reader, cancellation, deletion, due filtering, scan
limit, SQL failure, Unicode and pre-send-claim coverage. Update its explicit
false-output expectation to pending. Remove seventeen copied selection/calendar
assertions: their behavior is exercised by that native probe and the real MB963
calendar/DST case. Remove three JOIN-delivery source pins now covered by the
real claim/due/idempotence probes; retain JOIN wiring, alias and help checks.
Net change: sixteen fewer assertions, no new test file,
process, sleep or dependency.

## Limits and operator workflow

Acceptance is the normal Sender contract; it is not IRC-server acknowledgement
or persistence of the in-memory output queue. If the release itself cannot be
written, pending state cannot be guaranteed: the retained claim and diagnostic
remain for investigation rather than a fabricated success. Existing scheduled
attempt budgets and queue policies are not expanded.

Use the delivered verify/apply scripts as `mediabot` on `teuk.org`. They check the
exact cumulative scope, run targeted tests and the full suite visibly with
`--progress`, then security/startup/inventory checks. Only after success is the
dev restarted and a new PID required to remain stable for ten seconds before
interactive `commit.sh`. VERSION remains native 3.8dev; no database migration,
production action or configuration change is included.
