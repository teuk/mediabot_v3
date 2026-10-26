# MB968 — Factoid write confirmation

The API v3 factoid write service previously swallowed exceptions from a
single-row fetch and did not check the statement error with `RaiseError=0`.
Consequently, `learn` could report an unknown channel and `forget` an unknown
factoid after an actual SQL failure. It also acknowledged deletion whenever
`execute` was true, including DBI's successful zero-row result.

## Change

- Inspect fetch errors before finishing the cursor and propagate the existing
  fixed service error. Genuine empty reads keep their existing outcomes.
- Inspect the affected-row count and statement error before finishing DELETE.
  Unknown or failed counts produce a service failure, not a success response.
- Keep the existing delete by authorized factoid id and channel id. A confirmed
  zero-row result is idempotent `not_found`; no retry by keyword is attempted.
- Preserve authentication, author/operator thresholds, upsert SQL and recall
  accounting. No schema, grant, configuration or stored-data migration.

If a delete commits but its affected-row count cannot be confirmed, the
command reports failure. It cannot promise that the original row remains;
the caller can read the current state before retrying.

## Regression coverage

`t/cases/1344_mb968_factoid_write_confirmation.t` uses actual SQLite statements
and independent connections. A DBI subclass injects prepare/execute/fetch and
row-count faults under both `RaiseError` modes. Tests verify no mutation after
an unconfirmed lookup, fixed errors, cursor cleanup, successful deletion,
missing resources, concurrent removal/replacement and committed-but-unconfirmed
deletion without retries. The official `factoids-v3` package is also exercised
through the real PluginManager command bridge in `on` mode.

The older MB760 statement fixture now implements DBI's `err` and `rows`
methods instead of relying on implicit successful fetch/deletion assumptions.

```sh
perl t/test_commands.pl --filter 'factoid|mb968' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
