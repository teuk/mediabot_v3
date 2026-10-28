# MB999 — Confirm reminder listings before reporting their contents

Base: `snap_mediabot_v3_teuk_20261028_182434.zip`, VERSION
`3.6dev-20261028_172421`, including MB998.

`remind show`, `remind list` and `remindlist` fetched rows without checking
the statement error at end of fetch. With DBI exceptions disabled, a failed
fetch could become an empty or partial reminder listing. With exceptions
enabled, prepare, execute or fetch failures could escape the command handler.
The first two branches also returned silently on a failed prepare or execute.

Each read now contains prepare, execute and fetch exceptions and confirms
end-of-fetch without an error before sending any listing or absence notice.
An unsuccessful read sends only a private `Database error.` notice and logs
a fixed operation label without SQL error details or reminder contents.
The statement is finished after the read decision; cleanup or logging errors
cannot override that decision or expose an incomplete result. Cleanup failure
alone does not invalidate an already confirmed complete read.

Only these three read paths change in `Mediabot/CommunityState.pm`.
The six parameterized queries, their bind values, existing list formats and
limits, channel filtering, private cross-channel views, pending-only selection
and `tell` alias remain unchanged. Creation, cancellation, snooze, scheduling
and delivery are untouched. No schema, configuration or dependency changes.

`1374_mb999_reminder_read_errors.t` adds 14 assertions through the real command
registry and an in-memory SQLite database. DBI RootClass faults exercise
prepare, execute and first/subsequent fetch failures, with RaiseError both off
and on. Healthy channel/private reads, genuine absence, UTF-8 text, outgoing
versus incoming reminders and the alias remain covered. Failed cleanup and
logging are also exercised. Reminder rows must remain identical before and
after every command. Eight assertions fail on the unchanged snapshot; all
fourteen pass with this correction. No external SQL, IRC or network is used.

Deployment must run the unfiltered suite with `--progress`, security audit and
startup integrity checks before restarting only `mediabot@dev.service` and
invoking the native `commit.sh`. A failed check must stop the procedure.
