# MB1120 — Distinguish Quotegame database failures from empty reads

Quotegame reads one eligible quote before creating a round. A failed
fetch could look like a successful empty result, and thrown DBI errors
could escape the command without a reply.

The command now confirms preparation, execution and fetch status
before publishing a round or reporting an empty result. It attempts
to close the cursor regardless of success. An error while closing
the cursor cannot change the confirmed query outcome. Failed reads
produce one private database notice and preserve the previous scores
and round state.

The SQLite fixture covers missing handles, failed preparation,
execution and fetch with RaiseError on and off, confirmed empty reads
and throwing cleanup. The existing successful quote and Unicode
scenarios still run. No SQL, schema or configuration change.
