# MB1102 — Trust only completely read radar diagnostics

## Fault and correction

The default !radar report treated SQL prepare/execute failures as empty data.
Its ghost query could therefore classify every online nickname as silent for
9,999 hours. Rate failures could report calm activity, while failed/partial
newcomer or talker reads could silently truncate the report. With RaiseError
enabled, exceptions could escape instead of producing a bounded user response.
The historical calendar mode already checked complete reads separately.

Give the standard mode one local row-reader used by its five SELECTs: rate,
last-message age, newcomers, ghost activity and conditional top talkers.
Require prepare and execute success, consume rows to EOF, then inspect the
statement error before cleanup. A rate/last-message aggregate must return one
row; its legitimate NULL values on an empty log retain their zero/no-age
interpretation. A missing aggregate row is a failed read.

On any read failure, emit one private Database error. notice and return before
the public header or accumulated lines are sent. Cleanup is best effort after
the read outcome is captured: a finish exception cannot replace a read failure
or discard a completely read result. The next request performs normal fresh
reads, without a latched failure or partial cached result.

SQL text, bind order, channel/event restrictions, thresholds, output wording,
newcomer/talker limits, live-log scope, optional nicklist and calendar mode are
preserved. The 9,999-hour sentinel still denotes a nickname without recorded
history after a successful ghost lookup; it is never inferred from a failed
lookup. This change does not create a transaction across separate SELECTs or
promise a cross-query database snapshot.

## Essential native coverage

Extend case 1426 and its real SQLite/DBI fixture. Translate only the MariaDB
calendar/interval functions at that test adapter boundary. Inject failures in
DBI prepare, execute, fetch before/after a row and missing-aggregate results,
with RaiseError both disabled and enabled. Real application code runs through
the radar module, compatibility facades and registered public command.

Three grouped checks exercise exact standard output and binds, empty logs,
unknown-history ghosts, bot exclusion, other-channel/event filtering, 44
failure/recovery cycles and 20 cleanup-exception scenarios. Late failures must
publish no partial report; subsequent success must return the original report.
Historical date, DST/year/leap, zero-day, bounded-window and fault tests remain.
Three duplicate calendar entry-point checks are replaced by the same native
entry points on real standard reports. Assertion count is unchanged; no new
file, child process, sleep, network access or runtime dependency is introduced.

## Operator workflow

The package checks the exact cumulative qualified state, applies only its four
paths and runs targeted tests plus the visible full suite with --progress.
Security, startup, inventory and diff checks must pass before the dev restart.
A distinct positive PID must remain active and stable for ten seconds before
interactive commit.sh. The native VERSION plan stays automatic in 3.8dev.
A stable process alone does not prove IRC reconnection. No production instance,
configuration or database schema is changed by this package.
