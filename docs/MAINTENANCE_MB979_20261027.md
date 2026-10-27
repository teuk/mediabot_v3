# MB979 — Contain native quote insertion failures

## Reproduced defect

The duplicate lookup in native `mbQuoteAdd` was guarded, but INSERT preparation,
execution, cursor cleanup and inserted-id retrieval could still throw through
the handler. With DBI RaiseError enabled, a preparation or execution failure
interrupted the command without its usual error notice. A cleanup exception
after a committed INSERT prevented the success response and contribution hook.
An execution result accompanied by a statement error could instead be treated
as successful after cleanup cleared the error.

## Change

Guard INSERT preparation/execution, inspect the statement error before cleanup
and attempt cleanup independently. On an unconfirmed execution, send the existing
`Database error while adding quote.` notice, without returning an id or running
the success log/contribution hook. Runtime failure messages omit driver details.

A failed acknowledgement does not prove the INSERT was rolled back. Do not
retry it automatically or claim that no data was written. A later explicit
command still uses the normal duplicate lookup, which finds an already
committed quote without inserting it again.

When execution is confirmed, cleanup failure does not invalidate it. Guard
optional inserted-id retrieval and retain the existing `mysql_insertid` / `?`
fallback. Capture the quote id before contribution callbacks, which may insert
rows on the same connection. Preserve public responses, author identity,
channel scope, duplicate behavior and the SQL schema.

## Regression coverage

`t/cases/1355_mb979_native_quote_insert_confirmation.t` runs actual SQLite
writes with foreign keys and a second connection observing committed state.
It calls both native facades and the real `q` / `quote` registry handlers.

Coverage includes RaiseError disabled/enabled, SQL preparation failure,
foreign-key failure, explicit exceptions, lost acknowledgements after commit,
statement error status before cleanup clears it, cleanup failures with and
without a confirmed write, inserted-id exceptions, anonymous/authenticated
authors, Unicode, duplicate recovery and unrelated channel data. A real second
INSERT inside the contribution callback proves that the quote id is captured
before the connection's last-insert id changes.

The regression contains 2,152 assertions: 388 fail against the supplied
snapshot, and all pass after the fix. Full-suite and audit results are recorded
in the delivery README. No configuration, grant, migration or plugin activation
change is included.

The existing MB668 source-order contract now locates the inserted-id call,
rather than requiring its old unguarded assignment spelling. It still rejects
a lookup placed after the contribution hook; the new runtime regression also
checks this ordering with real independent INSERTs.
