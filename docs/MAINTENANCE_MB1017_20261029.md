# MB1017 — Resolve channel letter case consistently for membership and duels

## Reproduced problem

The JOIN/NAMES nick registry retains a channel's supplied spelling. The native
membership and random-nick helpers looked up only that exact hash key. A command
received for `#TEST` therefore found no members when the snapshot was stored as
`#Test`, although the channel and its SQL-backed channel object were the same.
An actual registry-dispatched duel incorrectly reported its opponent absent.

The four duel state tables also used the unmodified command target. Statistics
and leaderboards appeared empty under another spelling. Where the native NAMES
setter had retained both spellings, another confirmed duel could update karma
before the original pair's 24-hour deadline because it used a separate bucket.

## Change

- Retain authoritative exact nick snapshots, including an empty snapshot. When
  no exact snapshot exists, resolve channel letter case using the existing
  lowercase channel-cache convention. Do not merge or mutate NAMES snapshots.
- Make random-nick selection use that same lookup, retaining the empty/unknown
  and malformed-entry guards and the existing random selection behavior.
- Key all duel statistics, cooldowns, streaks and last-result state by the
  lowercase channel name, and read the same record in the general leaderboard.
  Keep the received target for replies, policy, membership, hooks and audit.

Only `Mediabot/Helpers.pm` (the two nick lookup functions),
`Mediabot/Games/Duel.pm` (channel state keys) and the duel-record lookup in
`Mediabot/SocialHistory.pm` change at runtime. The karma statement, pair identity,
24-hour duration, dice/critical/fumble rules, achievement calls and success
accounting remain unchanged. No schema, configuration or dependency change.

This follows the project's existing lowercase channel convention. It does not
change network CASEMAPPING or equate punctuation variants, and it does not
combine conflicting duplicate NAMES snapshots. Exact snapshots retain priority.
Duel state remains process-local and restarts with the bot as before; no live
state migration or persistent score rewrite is performed by this patch.

## Regression and qualification

Eight focused assertions use the actual Helpers facade, native NAMES setter,
real command registry and leaderboard handler. A SQLite database executes the
complete paired karma upsert; the fixture bridges only the MariaDB upsert
syntax. Clock and dice are deterministic, without live IRC or SQL servers.
Seven assertions fail on the supplied unchanged snapshot and all eight pass
after correction. No existing test is edited, removed or skipped.

The checks cover unchanged nick snapshots, exact empty-list precedence, random
nick membership, mixed-case opponent lookup, repeated/reversed pairs, unchanged
karma during cooldown, stats/top/leaderboard consistency, exact deadline expiry,
streak continuity and independence of another channel. Existing Games policy,
self/absent-opponent rejection, draws and an actual SQL failure retain no false
win/cooldown/success accounting, and the fixture emits no warning.

Qualification commands:

```bash
perl t/test_commands.pl --filter 'duel|leaderboard|random.*nick|dynamic.*command|mb128|1392_mb1017|module_structure' --progress
perl t/test_commands.pl --progress
perl tools/security_audit.pl --quiet
perl tools/startup_integrity_check.pl --quiet
perl tools/mb_architecture_inventory.pl --check docs/generated/COMMAND_INVENTORY.md
```

The delivery README records actual full-suite outcomes and any failures also
reproduced on the unchanged source in this environment. The deployment procedure
stops at any failure and restarts only `mediabot@dev.service` after all checks.
The native `commit.sh` owns versioning, confirmation, commit and push. No remote
deployment, commit or IRC reconnection is claimed by offline qualification.
