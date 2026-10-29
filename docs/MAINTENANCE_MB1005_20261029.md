# MB1005 — Confirm userinfo reads before interpreting absence

Base: `snap_mediabot_v3_teuk_20261029_092111.zip`,
VERSION `3.6dev-20261029_081734`; MB1004 is already present.

## Failure and correction

`userinfo` interpreted a failed account fetch as an unknown user. A failed
hostmask query could become `Hostmasks: none`, and an interrupted fetch could
publish only its first rows. DBI exceptions could escape the command; raw
SQL exception strings were also logged on some paths.

The account and hostmask stages now catch prepare, execute and fetch errors
and check the statement error before best-effort cleanup. A failed account
read sends only `Database error while fetching user information.` privately
and does not query hostmasks. If only hostmasks fail, the confirmed account
fields remain available, followed by `Hostmasks: unavailable (database error).`
No partial mask list is published. Fixed operation labels replace raw SQL
error details in the failure log; logger and cleanup exceptions cannot
override the read outcome. Cleanup failure alone does not invalidate a
confirmed read.

## Scope

Only `Mediabot/Users/Profiles.pm::userInfo_ctx` changes at runtime. Public and
private registry entry points still require an authenticated Administrator
and respond through private notices. The existing queries, parameter binding,
password-presence-only projection, field defaults, genuine unknown users and
empty mask lists, mask ordering, maximum 20 masks, two per line and existing
line truncation are retained. No shared transaction, retry, schema change,
configuration change or write is added. `users` and `greet` are unchanged.
These remain two independent reads, not a common database snapshot.

## Regression coverage

`t/cases/1380_mb1005_userinfo_read_errors.t` adds eleven assertions through
the real public/private command registry and Context. In-memory SQLite is
seeded, then set read-only. DBI faults cover prepare, execute, fetch and
hostmask fetch interruption after a row, with and without RaiseError.
Coverage also checks unchanged account and mask rows, Unicode output,
password presence, empty and unknown results, Administrator/authentication
and syntax guards, mask bounds and pagination, and cleanup/logger failures.
Six assertions fail on the unchanged snapshot; all eleven pass after the fix.
No IRC, MariaDB server or external network is used by this regression.

The delivery README records the full-suite results and any failures also
reproduced on the original snapshot in this environment. No existing test
is removed or skipped for this fix. Native security and startup checks,
command inventory, credential scanner and forward/reverse patch checks are
part of delivery validation. Deployment and Git operations are left to the
provided procedure on `mediabot@teuk`; only dev is restarted there.
