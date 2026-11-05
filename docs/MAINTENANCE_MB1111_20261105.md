# MB1111 — RSS worker failures follow the feed's retry interval

The worker protocol can finish successfully while its RSS operation fails.
For example, if the worker cannot open its isolated database handle, it
returns an unsuccessful poll result inside a successful completion. The
parent used to log this result without advancing the feed's last attempt.
The unchanged last_poll_at made the feed due again at the next scheduler
tick, bypassing its configured interval.

The poller now reports whether its normal fetch-error write succeeded.
If an unsuccessful poll was not recorded, the parent uses the existing
record_poll_error path. The durable fallback contains a bounded error code,
not the raw child diagnostic. An already recorded fetch failure is not
written again. Successful timestamps, HTTP validators and pending items
are untouched by the fallback. It publishes no article. If the parent
database is also unavailable, this attempt cannot record a durable delay.

The native repository fixture runs the scheduler with a worker that cannot
open its isolated database handle. It verifies the next tick skips the feed
and that the feed becomes due after its configured interval. A second
fixture counts SQL writes for both a normally recorded fetch failure and
one whose initial write is rejected. Both use a local SQLite database with
MariaDB date functions supplied by the existing test harness.

No schema, configuration or dependency change.
