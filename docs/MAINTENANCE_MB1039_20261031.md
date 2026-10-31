# MB1039 — Consistent history fetch failure handling

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_142707.zip`.
Base: `4dfa4b8743c750a0e7d256564a72af8c77b7f957` (MB1038),
VERSION `3.8dev-20261031_132659`.

The shared live/archive history reader handled false DBI fetch results via
statement err, but an enabled RaiseError caused fetch to escape before cleanup
or the existing live_ok/tainted decision. Its callers, including wordcount,
could therefore lose their normal database-error or best-effort handling.

Each fetch is now guarded separately. A fetch exception is recorded before
cleanup and follows the same policy as a false return with statement err:

- Live failure: live_ok=0; no archive query is attempted.
- Archive failure before any row: the completed live result remains usable.
- Archive failure after a row: tainted=1 and live_ok=0; the caller must discard
  its partial aggregate.

Callbacks remain outside the SQL guard, so consumer exceptions still propagate.
Already-delivered rows are not rolled back from caller-owned accumulators; the
status explicitly tells callers whether they may publish their result.
No query, binding, source policy or additional retry is introduced. Reading
remains streaming rather than buffering whole result sets.

Sixteen assertions use actual DBI SQLite handles and attached archive tables.
Native set_err injects fetch failures before/after one row with RaiseError off
and on. Seven fail on unchanged code; all sixteen pass after correction.
They cover cleanup that clears the error or throws, true empty results,
archive policy, channel bindings, callback failures and the actual wordcount
registry handler refusing partial totals. No live SQL server or IRC connection.

No production SQL/schema, configuration, dependency, radio or YouTube change.
The delivery requires the full --progress suite and audits before a dev-only
restart and native automatic 3.8dev commit. VERSION is not edited manually.
