# MB994 — Confirm birthday reads before reporting results

Base: `snap_mediabot_v3_teuk_20261028_154006.zip`, VERSION
`3.6dev-20261028_143148`. Prior corrections and French Trivia remain present.

## Reproduced defect

The birthday lookup and upcoming-birthdays query did not distinguish normal
end-of-results from a failed fetch. With DBI RaiseError disabled, a failed
lookup could announce an unknown user, and an interrupted list could report
no upcoming birthdays or publish only the rows fetched before failure.
With RaiseError enabled, prepare, execute or fetch exceptions escaped the
command. Some failed lookups returned without any user-facing error.

Both read paths now bound prepare/execute/fetch with an exception guard and
check the statement error before cursor cleanup. Upcoming birthdays are not
published until fetching completes successfully. Failures produce only the
existing private `Database error.` notice and a fixed operation diagnostic.
Cursor cleanup and diagnostic logging are best-effort and cannot replace a
known failed read with another exception or a partial successful response.
Cleanup failure alone does not invalidate an already confirmed result.

Successful public/private replies, known users without a stored date,
confirmed unknown users and empty lists retain their existing messages.
The calendar helpers, DST/Feb 29 observance, 30-day window, sort and ten-item
limit are unchanged. Add/delete writes and authorization are unchanged.
Only `Mediabot/Users/Birthdays.pm` changes at runtime. No SQL schema,
configuration, dependency, Trivia, dice or production deployment changes.

## Verification

The new regression contains 17 assertions through the real registered
birthday handler and Context. It uses real SQLite/DBI handles and injects
prepare/execute/fetch failures with RaiseError off and on, including failure
after one genuine row. It verifies no partial output, false absence,
escaping exception, data modification or successful-command audit entry.
Healthy reads cover public and private replies, unset dates, absent users,
today/upcoming filtering and empty results. Cleanup plus logger failures
cannot hide a failed read. Fifteen assertions fail before correction.

The delivery README records targeted/full suite results, security audit,
startup integrity and command-inventory verification. No test is excluded.
The user procedure runs the complete suite with --progress and stops on any
failure before restarting dev or invoking the native commit/push script.
