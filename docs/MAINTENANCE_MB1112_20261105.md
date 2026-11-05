# MB1112 — Complete SQL reads before publishing compatibility scores

The first two SQL dimensions in !compat already stop when their live read
fails. The co-presence dimension used a separate query and treated a
prepare or execute failure as zero pairs. It could also score the rows
already fetched when a cursor stopped early. In either case the command
could publish a misleading score and count it as a successful invocation.

The co-presence read now checks prepare, execute and the cursor's status
at EOF. It checks that status before closing the statement and handles DBI
exceptions as well as false returns. On failure it gives the existing
private database notice and returns before publishing, recording progress
or accounting for the invocation. A successful empty cursor still means
zero pairs. The SQL, 90-day window and scoring formula are unchanged.

The existing compatibility fixture exercises a real local SQLite cursor
under both successful and injected failing outcomes. Six alternating
messages arrive before one of the injected failures, enough to produce a
nonzero component on the original code. The tests check private failure
output, absence of public scores or success side effects, and statement
cleanup. The existing vocabulary and empty-result scenarios still pass.

No schema, configuration or dependency change.
