# MB981 — Confirm native quote views before recall accounting

## Reproduced defect

Native `mbQuoteView` treated a failed first fetch as a missing quote when DBI
did not throw. Prepare/execute/fetch exceptions could escape the handler. A
returned row with a statement error could be published and its recall counter
incremented before the read was confirmed. An exception during cleanup could
also interrupt a valid view after its public response.

## Change

Guard preparation, execution and fetching. Inspect the fetched row or absence
and the statement error before cleanup can clear its evidence. On a failed
read, use the existing private `Database error while reading quote.` notice
without public text/absence, a successful return value, recall accounting or
successful command logging. Runtime messages omit raw driver details, and no
automatic retry is introduced.

Attempt reader cleanup independently before display and recall accounting.
If the read is confirmed, retain its ordinary result even when cleanup fails.
Keep author attribution, Unicode excerpts, channel binding, genuine absence,
return values and existing best-effort recall behavior. The view does not
modify the random-quote exclusion memory. Only `mbQuoteView` changes in runtime
code; the SQL schema, grants, configuration and plugin API remain unchanged.

## Regression coverage

`t/cases/1357_mb981_native_quote_view_reads.t` runs real SQLite reads/writes
with foreign keys and a second connection observing committed counters. It
calls both native facades and the actual `q view` / `q v` registry handlers
under both DBI error modes.

Coverage includes prepare/execute failures, non-throwing and throwing fetch
failures, returned rows carrying an error, cleanup that clears error state,
cleanup exceptions/false returns and explicit later recovery. Healthy cases
cover registered/anonymous authors, long Unicode excerpts, genuine absence,
other-channel ids, one recall per confirmed local view, optional counter
failures and unchanged random memory.

The regression contains 3,336 assertions: 360 fail on the supplied snapshot,
and all pass after the fix. Full-suite/audit results are recorded in the
delivery README. No production service or SQL server is contacted by this test.
