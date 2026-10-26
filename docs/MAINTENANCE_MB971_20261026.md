# MB971 — Native factoid read confirmation

## Problem

Native factoid reads did not contain all SQL exceptions or inspect DBI's
statement error after fetching. A failed fetch with `RaiseError=0` could look
like a missing fact or publish a partial list/ranking. With `RaiseError=1`,
prepare, execute or fetch errors could escape the handler. An unsuccessful
execution also skipped cursor cleanup on some paths.

## Change

A private CommunityState helper reads a complete detached result before any
caller renders it. It distinguishes a confirmed empty result from a failed
read, catches exceptions and finishes prepared cursors on success and failure.
The statement error is inspected before cleanup can clear it. A partial result
is discarded in its entirety.

The helper is used by `whatis`, detailed `factoid`, plain/filtered `factoids`
and `factoids top`. Existing SQL, result limits, ordering, channel scope and
successful output remain the same. Explicit commands use their existing error
notices. The `?keyword` shortcut keeps its existing silence on absence/error.
Failed reads cannot reach the recall UPDATE or successful recall metric.

No schema, grants, configuration or plugin activation changes are needed.

## Regression coverage

`t/cases/1347_mb971_native_factoid_reads.t` exercises CommunityState,
UserCommands and the Mediabot facade through real Context objects. SQLite
executes the actual queries; its DATE_FORMAT compatibility function supports
the existing metadata query. A DBI subclass injects errors for prepare,
execute, the first fetch and a fetch after one listing/ranking row.

Both DBI error modes are covered. Tests check fixed responses or quiet silence,
no partial output, cursor cleanup even when finish clears the error, no recall
mutation after an unconfirmed read, successful recall accounting, metadata,
listing/ranking output, confirmed absence and another channel's sentinel data.

```sh
perl t/test_commands.pl --filter 'factoid|community_state|mb971|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
```
