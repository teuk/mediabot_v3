# MB1029 — Consistent activity counts (2026-10-30)

## Source and scope

Reviewed user snapshot: `snap_mediabot_v3_teuk_20261030_184532.zip`.
All tracked bytes match public commit
`7c03e452875f7546c56515b517f5c95acfbe00d7` (MB1028), with
`VERSION=3.8dev-20261030_172005`.

The runtime change is limited to `Mediabot/Stats/Activity.pm`.
The package also adds this record, one changelog entry and one focused test.
The native commit helper continues the already-open timestamped 3.8dev line;
VERSION is not edited by the patch.

## Confirmed defects

### Monthly comparisons discarded display-case identities

`monthstats Alice vs Bob` normalizes its requested nicknames to `alice` and
`bob`, then indexes a grouped SQL result using the original returned spelling.
A case-insensitive SQL grouping can return `Alice`, `ALICE` or `bOB`.
Those keys do not match the lookup keys, so real counts become empty bars.

Normalize returned keys with the same `lc` operation as the requested names,
and add counts under that key. The date/channel restrictions, SQL, chart
scaling, output order, single-nickname mode and genuine empty result stay intact.

### Rank and displayed counter counted different messages

`stats` already excludes `!stats` and `m stats` invocations from its message
count and denominator. Its grouped ranking query omitted those exclusions.
The current command could therefore make the caller's own grouped count
greater than the count just displayed, incorrectly worsening their rank.
Repeated stats invocations could also incorrectly elevate other participants.

Apply the identical exclusions in the ranking query. Preserve the existing
channel, public/action, live/archive merge, case normalization and strict
greater-than tie rules. No new command spelling or archive policy is introduced.

## Regression coverage

`t/cases/1402_mb1029_activity_counter_consistency.t` calls the registered native
`monthstats` and `stats` handlers through real contexts. DBI/SQLite executes the
actual filtering, bound values, grouping and counts. The fixture adapts only
MySQL's date spelling to a fixed test calendar and implements DATE_FORMAT and
REGEXP locally; it makes no claim to reproduce every MariaDB behavior.

Nine assertions cover mixed-case monthly results, equivalent caller spelling,
unchanged single-user charts, genuine absence, read-only data, self rank,
another user's rank, ties/actions/NULL text/non-command words and warnings.
Four assertions fail on the unchanged runtime. All nine pass with the fix;
the focused activity/archive selection passes 273/273 assertions in eight files.
No existing test is removed, weakened, skipped or excluded.

Full-suite results and execution-environment limits are recorded in the
delivery package. The operator procedure requires the complete suite to pass,
then security/startup/inventory checks, before restarting the development
service and invoking the local interactive commit helper. It changes no
production instance, database data, configuration, dependency, tag or release.
