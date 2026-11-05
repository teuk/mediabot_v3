# MB1115 — Retire removed timers even if cursor cleanup fails

remtimer first deletes the stored row in autocommit mode. If the DELETE
succeeds, the database change is already confirmed before the statement
is closed. A thrown finish() exception previously interrupted the
command at that point, leaving a timer active after its row was gone.

The statement close is now best-effort after the successful DELETE.
The requested timer is removed from the registry, stopped and detached
from the event loop, with the existing notice and audit. This also
applies when a successful DELETE confirms the row was already absent.
Failed preparation or execution still leaves the live timer untouched.

The command-registry fixture exercises real SQLite DELETE statements
and native IO::Async timers. It injects a false result or exception at
cursor close and checks the stored row, timer, unrelated timer, notice
and audit. No change to schema, configuration or permissions.
