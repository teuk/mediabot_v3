# MB1004 — Confirm account statistics before publishing users output

Base: `snap_mediabot_v3_teuk_20261029_085532.zip`, VERSION
`3.6dev-20261029_073501`, including MB1003.

The native `users` command read its total and level breakdown without checking
statement errors after fetch. A failed total read could become a fabricated
zero, while a failed breakdown could be published as an empty or partial list.
Prepare, execute and fetch exceptions could also escape the handler.

Only `userStats_ctx` in `Mediabot/Users/Profiles.pm` changes. The total now
requires a defined, error-free aggregate result; a real zero remains valid.
The level breakdown must reach error-free EOF before output. Both reads
contain DBI exceptions, decide their outcome before cleanup, and attempt
statement cleanup independently. A failure keeps the existing stage-specific
private notice and logs a fixed operation label without raw driver details.
A failed total stops before opening the breakdown query. Cleanup or failure
logging cannot mask an unsuccessful read, and cleanup failure alone does not
invalidate confirmed results.

Authentication and the existing Master gate, the two SQL statements and their
ordering, level labels/defaults, one-line private output and successful empty
results remain unchanged. The command retains two independent reads; this
change does not add a transaction or promise a shared concurrent snapshot.
The userinfo and greet handlers are byte-identical to the supplied snapshot.
No schema, configuration, dependency or authorization changes are included.

`1379_mb1004_user_statistics_reads.t` adds ten focused assertions through the
real public/private `users` registry entries and Context with a read-only
in-memory SQLite fixture. DBI faults cover each stage with RaiseError off and
on, including no aggregate row and a breakdown interrupted after its first
row. Other cases cover zero totals, Unicode and level ordering, private output,
access guards, cleanup/logger exceptions and unchanged account rows.
Six assertions fail on the original snapshot; all ten pass after correction.
No external SQL, IRC or network is used.

Acceptance retains the full unfiltered suite with `--progress`, security audit
and startup integrity checks before restarting only dev and invoking native
`commit.sh`. Any failed check must stop the procedure.
