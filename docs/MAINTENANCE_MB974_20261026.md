# MB974 — Confirm the native quote duplicate lookup

## Reproduced defect

Before adding a quote, the native `q add` / `q a` handler searches for the
same text in the current channel. It previously interpreted an undefined
`fetchrow_hashref` result as confirmed absence without inspecting the DBI
statement error. With `RaiseError` disabled, a failed fetch could therefore
reach INSERT, including when that quote already existed. A returned row
accompanied by an error could also produce a misleading duplicate answer.
With throwing drivers, lookup exceptions escaped the handler instead of
using its existing database error notice.

## Change

`Mediabot/Quotes.pm::mbQuoteAdd` now contains duplicate-lookup prepare,
execute and fetch errors. It checks the statement status before cleanup,
since cleanup can clear that status. Any unconfirmed read stops before the
INSERT, contribution hook and successful command log, using the existing
`Database error while checking quote.` notice. Lookup logs identify only
the failed stage; they do not interpolate the driver error.

Every allocated lookup cursor gets a cleanup attempt, even after a failed
execute or fetch. Cleanup is isolated from the completed lookup: a cleanup
exception cannot turn a confirmed duplicate into an insertion, nor suppress
the normal addition after confirmed absence. There is no automatic retry.

Healthy duplicate responses, public addition confirmations, channel-scoped
matching and authenticated/anonymous author attribution retain their existing
behavior. This change concerns the native duplicate lookup; it does not make
the separate SELECT and INSERT atomic against concurrent additions and does
not change the subsequent INSERT error handling. No SQL schema migration is
required.

## Regression coverage

`t/cases/1350_mb974_native_quote_duplicate_read.t` uses actual SQLite queries
and writes, DBI statement subclasses for failure injection, and a separate
database connection to observe persisted rows. It exercises:

- The `Mediabot::Quotes` and `Mediabot` facades and the actual context
  dispatcher for both `add` and `a`.
- Both DBI `RaiseError` modes; prepare, execute and fetch failures; an
  explicit fetch exception; and a returned row with a DBI error.
- Existing and absent quote text, no INSERT or contribution on failed reads,
  no implicit retry, independent cursor cleanup and fixed error reporting.
- Healthy duplicate detection, cleanup exceptions/false returns, text
  already present in another channel, real inserted ids, authenticated and
  anonymous authors, and recovery on a later explicit command.

The 1,480-assertion regression fails 341 assertions against the supplied
snapshot and passes after the change. The targeted quote/module suite passes
3,235 assertions across 35 files. Full-suite and audit results are recorded in
the delivery README. Run the complete suite on the deployment host before
restarting dev and committing with the native script.
