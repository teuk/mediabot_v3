# MB980 — Publish only confirmed native quote searches

## Reproduced defect

Native `mbQuoteSearch` accumulated rows until `fetchrow_hashref` returned no row,
without inspecting the statement error. An interrupted search could therefore
publish a partial ranking as complete, or report that no quote matched when
the first fetch failed. SQL prepare/execute/fetch exceptions could also escape
the handler. Cursor cleanup could interrupt an otherwise confirmed search.

## Change

Guard preparation, execution and fetching. Inspect the statement error after
each fetch, including end-of-results, before cleanup can clear its evidence.
Publish the accumulated rows only after the entire read is confirmed. A failed
search uses the existing private `Database error during search.` notice,
without partial results, a successful count or a successful command log.
Runtime failure messages omit raw driver details. Do not retry automatically.

Attempt cursor cleanup independently. A cleanup failure after a confirmed read
does not invalidate its result. Preserve the SQL, bound parameters, literal
LIKE escaping, AND matching, relevance/newest-id ranking, requesting-channel
scope, 51-row detection of an overbroad search, ten-id summary cap and excerpts.
The command remains read-only and does not increment quote recall counters.

Only the native search handler changes. The `quote <nick>` command, plugin API,
SQL schema, grants and runtime configuration are unchanged.

## Regression coverage

`t/cases/1356_mb980_native_quote_search_reads.t` runs real SQL against SQLite
with foreign keys and `PRAGMA query_only=ON`. It exercises both native facades
and the actual `q search` / `q s` registry handlers under both DBI error modes.

Coverage includes prepare/execute failures, first-row and partial fetch
failures, explicit exceptions, a returned row carrying an error, genuine empty
results and more than 50 matches. Cleanup deliberately clears the error, so
the caller must inspect it beforehand. Confirmed results survive cleanup
exceptions and false cleanup returns. An explicit later command recovers
without an implicit retry.

Healthy cases verify anonymous attribution, relevance ordering, descending ids
for ties, multiword AND matching, literal `%`, `_`, `!` and regex characters,
Unicode, channel isolation, empty/overbroad responses, summary bounds and
unchanged quote rows/recall counters.

The regression has 4,032 assertions: 812 fail against the supplied snapshot;
all pass after the fix. Full-suite and audit results are recorded in the
delivery README. No production service or SQL server is contacted by this test.
