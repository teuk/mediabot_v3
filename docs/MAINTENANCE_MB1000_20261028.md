# MB1000 — Contain birthday UPDATE failures and preserve their outcome

Base: `snap_mediabot_v3_teuk_20261028_184528.zip`, VERSION
`3.6dev-20261028_174508`, including MB999.

The birthday add and delete paths did not contain exceptions from preparing
or executing their UPDATE. A DBI exception could escape the command handler.
They also called statement cleanup before acknowledging a successful write,
so a cleanup exception could hide an already applied birthday change.
Clearing a birthday through `birthday add user <name>` interpolated an
undefined date into its audit argument and emitted a warning.

Only the UPDATE handling in `_birthday_add_ctx` and `_birthday_del_ctx`
changes. Preparing and executing the existing parameterized statements now
run within an exception boundary. An unconfirmed write sends a private
`Database error.` notice, logs a fixed operation label without raw SQL error
details, and emits no success notice or success audit. Statement cleanup and
failure logging are best-effort and cannot override the write decision.
Confirmed writes keep their acknowledgement and audit even if cleanup fails.
The clear-through-add audit retains its previous text without interpolating
an undefined value.

There is no automatic retry or rollback. A lost acknowledgement can occur
after the UPDATE has already been applied; an error therefore does not prove
that the stored birthday is unchanged. DBI's true zero-row result (`0E0`)
remains successful, including clearing a birthday that is already empty.

Authentication, Administrator checks, date validation, user lookup, SQL and
bind parameters, reply routing and successful messages remain unchanged.
Read-only birthday commands and calendar helpers are byte-identical to the
snapshot. No schema, configuration or dependency change is included.
This correction does not change the shared `getIdUser` or `logBot` helpers.

`1375_mb1000_birthday_write_errors.t` adds 15 focused assertions through the
real command registry, Context and an in-memory SQLite database. It injects
UPDATE prepare/execute failures with DBI exceptions off and on; exercises a
real UPDATE followed by a lost acknowledgement without retrying; verifies
true-zero success, cleanup and failure-logger exceptions, authentication and
date guards, date normalization, clearing, audits and unrelated users.
Eight assertions fail on the original snapshot; all fifteen pass after the
correction. Tests use no external SQL server, IRC connection or network.

The delivery procedure runs the unfiltered suite with `--progress`, security
audit and startup integrity checks before restarting only dev and invoking
the native `commit.sh`. Any failed check must stop the procedure.
