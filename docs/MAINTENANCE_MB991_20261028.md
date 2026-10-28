# MB991 — Reject empty poll fields before replacing votes

Base: `snap_mediabot_v3_teuk_20261028_141114.zip`, VERSION
`3.6dev-20261028_125858`. The French Trivia integration and earlier fixes remain
unchanged; this correction concerns poll creation only.

## Reproduced defect

Poll creation counted fields without verifying their contents. Whitespace-only
questions/options were accepted. Perl's default split also discarded trailing
empty fields, so a final separator could silently hide an empty option.
These malformed commands could replace an existing poll and erase its votes:

```text
poll | A | B
poll Question | A | | B
poll Question | A | B |
poll weighted 60 Question | A:2 |
```

The parser now retains trailing fields and requires a nonempty question and
all options after trimming. Invalid input returns the existing private syntax
notice before changing polls, votes, creation metrics or successful audit logs.
Valid labels containing `0` remain valid: the guard checks emptiness, not truth.

Only the parsing guard in `Mediabot/CommunityState.pm::mbPoll_ctx` changes at
runtime. Valid weighted/Unicode options, timeout handling, replacement of a
poll with valid input, the Master gate, vote/result/stop logic and other
channels retain their existing behavior. No SQL or configuration changes.

## Verification

The new test contains 19 assertions through the actual registered poll/vote
handlers and real Context authorization. It creates polls and votes in two
channels, then verifies that malformed input preserves the complete poll,
metrics and audit state. It also covers invalid input without an existing
poll, valid weighted and zero labels, and privilege denial. Twelve assertions
fail before correction; all 19 pass afterwards.

The targeted selection passes 127/127 assertions in nine files. Security audit:
GO, all 37 invariants. Startup integrity and generated command inventory pass.
Full-suite results are in the package README. Process checks 1151 and 828 also
fail against the unchanged snapshot in this environment; none are excluded.

The installation procedure runs the full suite with --progress and stops on
any failure before restarting dev or invoking the native commit/push script.
