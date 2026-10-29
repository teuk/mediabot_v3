# MB1009 — Urgent reminder scheduling

Base: `snap_mediabot_v3_teuk_20261029_122149.zip`,
VERSION `3.6dev-20261029_111755`; MB1008 is already present.

## Reproduced defect

The native reminder handler prepended its `[!] ` urgency metadata before
looking for a scheduling prefix at the beginning of the message. Thus
`remind ! Friend in 2h Un café` stored `[!] in 2h Un café` without an `[at:...]`
deadline. The recipient's next message could trigger immediate delivery,
despite the requested two-hour delay. The same problem affected the `tell`
alias and other one-off scheduling forms, including French `dans` and `at`.
Zero or unrepresentable urgent delays also bypassed normal delay validation.

## Correction and scope

For urgent, non-recurring reminders, temporarily remove only the internally
added urgency prefix while parsing the scheduling text. Restore it after
the existing parser has added its timestamp and before checking the final
512-character storage budget. The stored one-off message becomes
`[!] [at:TIMESTAMP] body`; the existing delivery code already recognizes
timestamps anywhere in the message and preserves the urgency marker.

Only `Mediabot/CommunityState.pm::mbRemind_ctx` changes at runtime. Scheduling
grammar, local-calendar resolution, relative-duration arithmetic, SQL, user
and channel checks, pending limits, audit, Unicode content and delivery/claim
logic are unchanged. The parser comment now correctly spells its existing
compact supported form `1h30m`. No new scheduling syntax is introduced.
Daily/weekly reminders retain their existing metadata and calendar handling;
their message body is not reinterpreted as a one-off delay. Plain urgent
messages and ordinary scheduled reminders retain their original output.
No schema, configuration, dependency or other module changes.

## Regression coverage

`t/cases/1384_mb1009_urgent_reminder_delay.t` adds ten focused assertions using
the actual public `remind`/`tell` registry, Context, native delivery handler
and compatibility facade, controlled time and SQLite. No external SQL or
IRC server is used. Cases cover:

- Urgent English/French relative delays and absolute local time.
- Existing minute/day/week/tomorrow forms with exact stored deadlines.
- No claim or delivery immediately or one second early, followed by exactly
  one delivery at the deadline, with another channel's reminder untouched.
- Rejection of zero and unrepresentable urgent delays before INSERT/audit.
- Ordinary and plain urgent reminders, literal non-leading time words,
  unchanged daily/weekly metadata and message bodies.
- Exact 512-character Unicode storage boundary including both metadata tags,
  caller arguments, confirmation text, recipient/channel bindings and audit.

Seven assertions fail on the original snapshot; all ten pass after the fix.
Existing tests are retained without modification. The delivery README records
targeted/full-suite results, original-snapshot process checks, native security,
startup integrity, command inventory and forward/reverse patch validation.
The procedure restarts dev only after the full suite passes, then invokes
native `commit.sh`; no live deployment or publication is performed here.
