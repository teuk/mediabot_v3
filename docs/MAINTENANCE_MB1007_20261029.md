# MB1007 — Trivia answer deadlines

Base: `snap_mediabot_v3_teuk_20261029_111446.zip`,
VERSION `3.6dev-20261029_084754`. This snapshot contains MB1005 but not MB1006.
The delivery includes the unchanged, previously reviewed MB1006 patch before
the new MB1007 patch, so both fixes can be applied with one full-suite run.
Each step is checked for prior application independently.

## Defect and correction

A question recorded a fractional start time but created its deadline using
integer `time()`. Answer handling then compared integer time with `>`.
This rounded the deadline and could accept a correct answer at expiry or
just afterward in the same integer second, updating both session and stored
scores and achievements after the intended deadline.

The start and deadline now share one `Time::HiRes::time()` sample when the
ready question is installed. The deadline is start plus the validated
configured timeout. Answer handling samples the same clock once, expires
when arrival is greater than or equal to the deadline, and uses that arrival
sample for the half-time hint. The configured duration is retained in full.

The existing lifecycle is retained: expiry is announced on the next incoming
message, not by a newly added timer. No automatic next round is introduced.
EN/FR messages, answer matching, timeout configuration limits and fallback,
score SQL, successful awards, session scores, achievements, channel scope,
question providers and corpus are unchanged. No schema or configuration
change is required. Runtime changes for MB1007 are confined to
`Mediabot/Games/Trivia.pm`.

## Focused verification

`t/cases/1382_mb1007_trivia_answer_deadline.t` adds six assertions using the
native trivia start registry, the real answer handler and compatibility
facade, a controlled fractional clock, an offline asynchronous completion
fixture and SQLite score persistence. It checks:

- Full question duration from readiness, valid timeout bounds and fallback.
- One successful award immediately before expiry, without duplicate credit.
- Exact expiry, fractional lateness and the existing later-message timeout.
- No late SQL write, achievement or progress event; existing scores survive.
- EN/FR feedback, other-channel state, one half-time hint and inactive guards.

Three assertions fail on the original snapshot; all six pass after correction.
No network, IRC connection or database server is used by this regression.

The existing `658_mb443_trivia_answer_accent_boundary.t` probe already freezes
core time. Its high-resolution clock is aligned to that same fixture instant
because Trivia now reads that clock for deadline checks. Its assertions and
answer/encoding coverage are unchanged; no test is skipped or reduced.
The source contract in `1061_mb738_achievement_timezone_accuracy.t` now checks
the sampled precise start, its use in both stored start and deadline, and the
existing high-resolution Sniper elapsed-time calculation. Its assertion
count is unchanged; it no longer requires a direct call inside the hash.

The delivery README records combined targeted/full-suite results, original
snapshot comparisons for local process checks, native security/startup and
inventory results, and forward/reverse checks for both patches. The procedure
restarts dev only after all checks pass, then invokes native `commit.sh`.
No live deployment, commit or push is performed while preparing this delivery.
