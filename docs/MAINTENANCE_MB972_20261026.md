# MB972 — Native factoid store failures

## Problem

Native `learn` used DBI prepare/execute directly. Exceptions from these calls
could escape the handler. Execution failures without exceptions returned an
error notice but skipped cursor cleanup. A cleanup exception after successful
execution also interrupted confirmation and contribution bookkeeping even
though the factoid had already been stored.

## Change

Contain prepare/execute failures and attempt cursor cleanup independently on
every path with an allocated statement. Return the existing fixed failure
notice on an unconfirmed write, before achievements, the success notice and
the successful-learn metric. Do not retry automatically.

A confirmed execute keeps the normal success path even when cursor cleanup
fails. DBI's true zero (`0E0`) remains a valid acknowledgement for an unchanged
UPSERT. Each confirmed explicit command invokes contribution accounting once.
SQL, author attribution, UPSERT semantics, schema and configuration are unchanged.

An error does not guarantee absence: the database may commit a write before
its acknowledgement is lost. In this case the command reports failure and
withholds success bookkeeping. A subsequent read can establish the current
state; an explicit retry uses the existing author-preserving UPSERT.

## Regression coverage

`t/cases/1348_mb972_native_factoid_store.t` exercises CommunityState,
UserCommands and the Mediabot facade through actual Context and User objects.
SQLite performs real writes; the driver translates only the existing MySQL
UPSERT syntax. Fault injection covers prepare, execute, acknowledgement loss
after actual commit and cleanup after confirmed execution, with both DBI modes.

Assertions cover fixed notices, contained exceptions, cursor cleanup, metrics,
accounting, stored data, explicit recovery, no implicit retries or duplicates,
retained authorship and another channel's sentinel record.

```sh
perl t/test_commands.pl --filter 'factoid|community_achievements|mb972|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
