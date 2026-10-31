# MB1037 — Timer removal ownership and SQL failures

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_111905.zip`.
Base: `2f64eb396eb56f29400b7073aabff9fd48552043` (MB1036),
VERSION `3.8dev-20261031_100819`.

`remtimer` could delete a stored row inside a transaction owned by another
caller, stop/detach its Periodic timer and announce success. A later rollback
restored the row without a running timer. DBI prepare/execute failures with
RaiseError enabled also escaped the handler instead of producing its existing
database-error response; a missing handle caused another exception.

The removal now requires a database handle in AutoCommit mode, matching the
existing addtimer ownership guard. It does not commit or roll back a caller's
transaction. Prepare/execute exceptions are handled like false DBI returns;
failed deletion keeps the native timer registered, running and attached.
Failed-statement cleanup is contained without changing the main error result.

The successful removal and already-absent-row cleanup paths remain unchanged,
including stop-before-detach and their audit. Owner authorization, interval
policy, timer callbacks and the other timers remain unchanged.

Nineteen assertions invoke the actual command registry and Context using real
DBI SQLite, native IO::Async::Timer::Periodic objects and native loops. A missing
table and a refusing DELETE trigger exercise both RaiseError modes. Five fail
on the unchanged source; all nineteen pass after correction. The transaction
case verifies unrelated pending work remains caller-owned through rollback.
They contact no live database server or IRC network and wait for no timer tick.

The SQLite schema is an isolated test fixture only. No production SQL/schema,
configuration, dependency or radio/YouTube change. The delivery requires the
full --progress suite and audits before restarting only dev and invoking the
native automatic 3.8dev commit flow; VERSION is not edited manually.
