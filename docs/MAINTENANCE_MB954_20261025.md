# MB954 — Source owners for birthdays and last-seen lookups

Date: 2026-10-25. Reference: MB953 snapshot supplied after installation,
VERSION `3.6dev-20261025_045920`.

## Extraction

| Owner | Existing functions |
| --- | --- |
| `Mediabot/Users/Birthdays.pm` | `userBirthday_ctx`, `_birthday_add_ctx`, `_birthday_del_ctx`, `_birthday_valid_date`, `_birthday_mmdd_from_value`, `_birthday_days_ahead`, `_birthday_next_ctx` |
| `Mediabot/Users/Seen.pm` | `mbSeen_ctx` |

The eight function bodies are byte-for-byte identical to the snapshot. The
remaining 50 bodies and UserCommands export list are unchanged. UserCommands
drops from 4,841 to 4,104 lines; two misleading adjacent legacy comments are
corrected/removed. Since the start of MB951, it has dropped from 7,885 lines.

Historical facade names and the two public bot methods stay available. The
domains resolve the existing transport hooks at call time; Birthdays also
preserves `getIdUser` interception. Domain-first loading does not import the
facade eagerly. The horoscope's existing calendar-helper call still works.

Birthday authentication/Administrator checks, storage formats, Gregorian date
validation, Feb 29 observance, local-calendar/DST arithmetic, the thirty-day
window and ten-result cap all use their original code. Seen retains the online
shortcut, persisted USER_SEEN lookup, archive fallback, requested-channel
scope, wildcard escaping and private/public routing.

## Verification

Existing calendar, scope, wildcard and enriched-seen tests follow the actual
owners. Broad SQL filter, sargability and career/archive failure checks include
Seen after extraction. No threshold, SQL clause or live-error assertion is
removed. Recursive encoding and pagination guards still cover both domains.

The existing birthday-next case adds three fresh-interpreter checks: both
domain-first orders and facade-first loading, eight alias identities, two real
Mediabot methods, century leap years, spring/fall DST, late transports, birthday
authentication/level denial and a real scoped seen online shortcut.

See the delivery's QUALIFICATION.md for exact local results and limits. Server
validation remains mandatory: changed Perl syntaxes, command inventory,
targeted tests, complete unfiltered suite, security and startup integrity.

## Application

The guarded installer checks exact before/after bytes, preserves existing modes
and announces a private backup. Failed validation restores only files written
by that attempt. Commit after successful server checks; VERSION is managed by
commit.sh. Service actions remain separate.

No schema, SQL, date policy, permissions, settings, dependencies, activations or
live instances are changed by preparing this extraction.
