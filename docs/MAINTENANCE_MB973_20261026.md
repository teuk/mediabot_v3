# MB973 — Native factoid recall identity

## Problem

Native `whatis` read a factoid value, then incremented hits by channel and
keyword. If another operation deleted and recreated that keyword between
those queries, the replacement received a hit for the original factoid's text.
The optional counter statement also skipped its cleanup call when execute threw.

## Change

Read the existing factoid id with the value. Increment hits using both that
observed id and the original channel. A concurrently removed or replaced row
produces no increment; a row moved to another channel is also excluded.
Do not retry or fall back to keyword-based accounting.

An absent or invalid id skips optional accounting. Counter prepare, execute or
cleanup failures remain non-fatal: the confirmed text is still displayed once,
including through the quiet `?keyword` path. The successful display metric
retains its existing meaning and does not claim that the SQL increment succeeded.
Allocated counter cursors receive a separate cleanup attempt after execution.

No schema, grant, configuration or plugin activation changes are needed.

## Regression coverage

`t/cases/1349_mb973_factoid_recall_identity.t` uses actual SQLite statements
and two independent connections. A peer removes, replaces or moves the row
after the confirmed read and before the counter query is prepared. It checks
public output, exact persisted counters, channel scope, no retries, both quiet
modes and all three native facades under both DBI error modes.

Additional cases cover counter prepare/execute/cleanup errors and unavailable
row identities. Existing native test fixtures now expose the actual factoid
identity and model identity-scoped counter bindings; their behavioral assertions
remain intact.

```sh
perl t/test_commands.pl --filter 'factoid|mb973|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
