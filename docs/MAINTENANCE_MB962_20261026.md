# MB962 — Scoped and reliable seen lookups

## Reproduced defects

- `!seen Alice #channel` could read global quit history when `#channel` was
  absent from the in-memory channel cache. That could report an unrelated
  channel's trace, even when the requested channel existed in SQL.
- A failed exact USER_SEEN read could fall back to old history as though no row
  existed. Wildcard fetch failures could produce incomplete or empty matches.
  RaiseError exceptions were not contained at these boundaries.
- Legacy live/archive messages and global quit reasons bypassed the cleanup
  and length bound already applied to USER_SEEN text.
- The optional activity counter guarded only execute. A prepare/fetch exception
  could discard an otherwise confirmed last-seen answer.

## Correction

Use the existing cached/database channel identity helper and stop privately
when the requested channel cannot be resolved. Keep global fallback available
for a genuinely unscoped private command.

A private bounded-result reader distinguishes empty success from SQL failure,
checks fetch errors, finishes statements and withholds partial results. The
optional activity read contains its complete SQL lifecycle. All legacy text
passes through the same existing formatter before transport.

Command names, authorization, nick casing, wildcard escaping, reply routing,
SQL schema, archive selection and newest-row merging remain unchanged.

## Regression

`1338_mb962_seen_scope_and_read_errors.t` runs the module, UserCommands import
and public Mediabot facade with actual SQLite queries and an attached archive.
It reproduces prepare/execute/fetch errors with RaiseError both enabled and
disabled, including a wildcard failure after one returned row. Only MySQL's
interval expression and UNIX_TIMESTAMP function are adapted to SQLite.

The fixture also checks uncached/unknown channels, global private lookup,
online shortcuts, literal underscore escaping, empty success, Unicode text,
live/archive/global cleanup and optional-count failures.

```bash
perl t/test_commands.pl --filter 'seen|mb962|mb576|mb577|mb578|mb579|birthday_next_real_30_days|module_structure' --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```

These are local regression checks. No live SQL/IRC server or running bot was
contacted. The full suite is included in the operator procedure before commit.
