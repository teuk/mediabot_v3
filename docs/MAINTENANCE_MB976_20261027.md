# MB976 — Confirm native quote counts

## Reproduced defect

The native `quotecount` / `quote count` handler published a count without
checking the statement error after `fetchrow_hashref`. With DBI `RaiseError`
disabled, a failed fetch could produce a public zero count even when the
channel contained quotes. The total-count branch also silently acknowledged
prepare/execute failure as success. Throwing database errors and cursor
cleanup exceptions could escape either branch.

## Change

`Mediabot/Quotes.pm::mbQuoteCount_ctx` now contains prepare, execute and fetch
errors, checks the DBI error before cleanup, and requires a returned aggregate
row with a nonnegative integer count. A failed or unavailable aggregate returns
the existing `Database error.` notice to the caller, without a public count or
success acknowledgement. Runtime logs use a fixed diagnostic without raw driver
details. No automatic retry is performed.

Every allocated statement gets a cleanup attempt independently of read success.
A cleanup exception after a confirmed read does not suppress the real count.
Confirmed zero counts remain valid. The SQL channel scope, author-prefix LIKE
escaping, anonymous inclusion in channel totals and public wording are retained.
No schema, configuration, grants or plugin activation changes are required.

## Regression coverage

`t/cases/1352_mb976_native_quote_count_reads.t` runs actual SQLite counts with
`PRAGMA query_only=ON` and DBI statement subclasses for failure injection. It
uses the `Mediabot::Quotes` and `Mediabot` facades and the real public registry
handlers for `quotecount` and `quote count`.

Coverage includes both DBI error modes, total and author counts, prepare/execute
failures, silent/throwing fetch failures, a returned row with an error, missing
aggregate rows/counts, cursor cleanup, later explicit recovery, real zeros,
anonymous quotes, another channel and an underscore in an author prefix.

The regression has 1,558 assertions: 452 fail against the supplied snapshot;
all pass after the fix. Full-suite and audit results are recorded in the
delivery README. Deployment must pass the full suite on teuk before restarting
dev and committing with the native script.
