# MB1002 — Distinguish failed greet reads from absence and retain zero text

Base: `snap_mediabot_v3_teuk_20261028_195452.zip`, VERSION
`3.6dev-20261028_185029`, including MB1001.

`greet` fetched a row without checking the statement error before cleanup.
A non-throwing fetch failure could therefore display `No greet` and audit a
successful lookup. With DBI exceptions enabled, prepare, execute or fetch
errors could escape the handler. A stored greeting containing the text `0`
also took the absence branch because the final check used Perl truthiness.

Only `userGreet_ctx` in `Mediabot/Users/Profiles.pm` changes. It now contains
prepare/execute/fetch exceptions and confirms the read before sending a
greeting, absence response or audit. An unsuccessful read retains the existing
error response and public/private routing, with a fixed failure log that omits
raw driver details. Cleanup happens after the read decision; cleanup or failure
logging exceptions cannot override it. Cleanup failure alone does not invalidate
a confirmed result. The final definedness check keeps `0` as a valid greeting.

The parameterized query, requested-channel selection, default caller nickname,
nick!ident cleanup, output destinations, successful audit and genuine missing,
NULL or empty greeting responses remain unchanged. Account statistics and
information handlers are untouched. No SQL schema, configuration, dependency
or authorization changes are included.

`1377_mb1002_greet_read_errors.t` adds nine focused assertions through the real
public/private registry entries and Context. An in-memory SQLite database is
seeded and then made read-only. DBI RootClass faults cover prepare, execute
and fetch with RaiseError off and on; other cases cover zero text, Unicode,
explicit/default channels and nicknames, absent/NULL/empty greetings, cleanup
and failure-logger faults, syntax guards, auditing and unchanged rows.
Five assertions fail on the original snapshot; all nine pass with the fix.
No external SQL, IRC or network is used.

Acceptance retains the full unfiltered suite with `--progress`, security audit
and startup integrity checks before restarting only dev and invoking the native
`commit.sh`. Any failed check must stop the procedure.
