# MB1053 — Historical radar calendar consistency

`radar Nd` previously rendered only dates returned by GROUP BY. Quiet dates
therefore vanished from the sparkline, average denominator and worst-day
selection. A rolling `NOW() - INTERVAL N DAY` filter could also span N+1 dates,
and lacked an upper boundary for later-day records. Chart, label and daily
average did not describe the same period.

Historical radar now means exactly N calendar dates including today, retaining
the existing 1..30-day clamp. The SQL-session `CURDATE()` is returned alongside
the grouped data and owns both the lower/upper range and displayed calendar.
The lower bound is N-1 days before today; the exclusive upper bound is tomorrow.
Timestamp comparisons remain on the raw `cl.ts` column. No host-timezone guess
or separate date query can move the window across midnight.

Existing DateTime performs UTC date-only arithmetic from the SQL anchor; UTC is
only an arithmetic carrier, not a new user/channel timezone policy. Every date
gets a bucket, including zero activity. Sparkline, total, average and extrema
use the same ordered buckets. Equal maxima/minima choose the earliest date.
The existing integer average formatting and eight sparkline glyphs are retained.
An entirely empty successful read keeps the familiar no-data response.

Prepare/execute/partial-fetch failure is reported privately as `Database error.`
before any chart is emitted. EOF is checked before cleanup can clear DBI's
status; a cleanup exception cannot replace a failed read or discard complete
data. The realtime radar branch is unchanged. Historical queries retain their
existing live CHANNEL_LOG scope and do not newly include archives. There is no
schema, configuration, permission, command or new dependency change.

## Validation

`1426_mb1053_radar_calendar_window.t` exercises the actual module and both
historical facades against real in-memory SQLite rows, with explicit SQL-calendar
functions and only MySQL interval syntax translated for SQLite. Outputs are
local sinks. No live MariaDB, IRC server, HTTP request or service is contacted.

Twenty-five assertions cover 1/2/7/30-day views and clamping, midnight bounds,
later-day records, other channels/events, silent days, stable extrema, different
host timezones, spring/autumn DST, leap/year boundaries, genuine empty results,
prepare/execute/fetch errors with RaiseError on/off and cleanup exceptions.
Twenty-four fail on the untouched public runtime; one passes. All twenty-five
pass after correction. The historical MB958 load-order fixture now supplies the
SQL calendar anchor and EOF status, checks parameterized calendar bounds and
keeps genuine emptiness distinct from a failed prepare. Its three load orders,
six outer assertions, scope/routing/formatter and other view checks are retained.
No test or assertion is skipped or removed.

The delivery qualification records targeted/full results, baseline environmental
failures and a clean public apply/test/reverse round trip.

## Operator flow

The package applies idempotently, then requires the visible full suite with
`--progress`, security audit, startup integrity, command inventory and whitespace
checks. Only after success does it restart `mediabot@dev.service`, require a new
positive PID stable for ten seconds and invoke the installed interactive
`commit.sh --skip-preflight` for commit/push and native 3.8dev VERSION progression.
The patch does not edit VERSION or the project README. No production deployment
is included; the private commit helper remains installed locally, never shipped.
