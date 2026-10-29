# MB1008 — Trivia score-write confirmation

Base: `snap_mediabot_v3_teuk_20261029_115300.zip`,
VERSION `3.6dev-20261029_105145`. MB1006 and MB1007 are already present.

## Defect

`checkTriviaAnswer` incremented `mediabot_trivia_db_saves_total` whenever its
eval completed without an exception, even if statement preparation failed,
execute returned false, or the channel could not be resolved. It could count
a save that had not happened. Raw exceptions were logged, and logger failures
could interrupt a valid round's acknowledgement. A cleanup exception after
a successful write could also incorrectly turn that write into a failed save.

## Result handling

The native handler now confirms the channel, an available AutoCommit database,
statement preparation, execute result and statement error before recording
a successful save. The single increment query accepts affected counts 1 or 2
as confirmation. Zero, `0E0`, unknown counts, statement errors and exceptions
are unconfirmed. The SQL and its channel/lowercase-nick bindings are retained.
Cleanup runs after deciding the outcome; its exceptions cannot change it.
Failure logging uses a fixed operation label without raw SQL error details
and cannot escape this write boundary.

The valid answer still earns its session point and normal public EN/FR win
response. If saving that point to the persistent leaderboard is unconfirmed,
the winner also gets one localized private notice. Correct-answer metrics,
session scores, achievements and multi-round continuation retain their existing
behavior. No retry is attempted: a lost acknowledgement may follow an actual
committed increment, so retrying could award another point. The notice says
unconfirmed, not that the stored point is definitely absent.

An existing caller-owned transaction receives no point write from this handler.
It is never committed or rolled back here. The point save is unconfirmed.
Normal native database connections use AutoCommit. No transaction wrapper,
schema, configuration, dependency, question provider, corpus or deadline change
is introduced. Runtime changes are confined to `Mediabot/Games/Trivia.pm`.

## Regression

`t/cases/1383_mb1008_trivia_score_persistence.t` adds nine assertions through
the actual native answer handler and its compatibility facade. In-memory
SQLite supplies real score writes; its private SQL bridge adapts only the
existing MariaDB upsert and NOW syntax. DBI faults exercise both RaiseError
modes and both languages, including prepare/execute failures, true-zero and
unknown affected counts, a written point followed by a lost or flagged
acknowledgement, cleanup/logger exceptions, missing database/channel and an
external transaction. Confirmed affected counts 1 and 2 retain successful
output. Checks cover actual rows, write counts, lowercased bindings, no retry,
single round credit, metrics, private warnings, achievements, other channels
and transaction ownership. Seven assertions fail on the original snapshot;
all nine pass after correction. No existing assertions are removed or changed.

This regression uses no external SQL server or IRC connection. A real MariaDB
server is not exercised in the preparation workspace. The delivery README
records targeted/full-suite results, original-snapshot process checks, native
security/startup checks, inventory and forward/reverse patch verification.
The procedure restarts dev only after the full suite passes, then invokes
native `commit.sh`. No live deployment or publication is performed here.
