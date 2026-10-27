# MB978 — Use the canonical author key in native quote statistics

## Reproduced defect

The native `q stats` contributor query joined `USER u ON u.id = q.id_user`.
The canonical schema in `install/mediabot.sql` defines `USER.id_user` as the
primary key, with no `USER.id` column. This made the contributor query fail:
with DBI `RaiseError` disabled the public summary omitted its top contributor;
with `RaiseError` enabled the exception interrupted the command.

A fixture with an unrelated legacy `id` column additionally demonstrates
incorrect attribution when that column happens to exist but differs from the
canonical account id.

## Change

Change only the contributor join to `u.id_user = q.id_user`, consistent with
the quote author foreign key and the existing API v3 statistics service.
The existing count, channel restriction, anonymous attribution, age rendering,
logging and empty-channel behavior are retained. No SQL schema migration,
configuration, grants or activation change is required.

This fix corrects the key used by the query. It does not change general SQL
failure handling or the tie-breaking policy of native quote statistics.

## Regression coverage

`t/cases/1354_mb978_quote_stats_author_key.t` executes real queries on read-only
SQLite with foreign keys, and uses both native facades and the actual `q stats`
registry handler. `UNIX_TIMESTAMP` is supplied as a SQLite function for the
unchanged aggregate query.

The fixture covers the canonical table without `id`, conflicting legacy ids,
both DBI error modes, registered and anonymous leaders, a busier author on a
different channel, empty channels, authenticated/anonymous callers, existing
logging and agreement with `QuoteServiceV3::stats`.

The regression has 318 assertions: 106 fail before the fix; all pass afterward.
Targeted, full-suite and audit results are recorded in the delivery README.
