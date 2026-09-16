# Achievements

Mediabot achievements are durable, channel-scoped milestones. A profile follows
the IRC identities that Mediabot has safely associated on one channel; progress
from unrelated channels is not merged into that profile.

## Civil time

Time-based achievements follow the channel community rather than the bot host
or an individual visitor. Every `CHANNEL` row has an IANA timezone such as
`Europe/Paris` or `America/Montreal`. IANA names are required because fixed
offsets do not model daylight-saving changes.

An authenticated Administrator or channel user at level 450 or above sets it
with:

```text
!chanset #channel timezone Europe/Paris
```

`!chaninfo #channel` displays the effective value. Fresh and migrated channels
default to `UTC`; choose the real community timezone before evaluating the
hour-based ladder.

Changing the timezone clears only Night Owl / Early Bird unlocks and their two
progress counters for that channel. The next message in the relevant local
time band rebuilds them from message history. This deliberate reconciliation
prevents counts classified under an old timezone from remaining authoritative.

MariaDB must have its system timezone tables populated for named-zone history
conversion. The `!chanset` command probes that capability and refuses the
change if conversion is unavailable. On Debian, an administrator can load the
tables and verify them with:

```bash
sudo mariadb-tzinfo-to-sql /usr/share/zoneinfo | sudo mariadb mysql
sudo mariadb -NBe \
  "SELECT CONVERT_TZ('2026-01-15 12:00:00', '+00:00', 'Europe/Paris');"
```

Application database sessions are pinned to UTC on every managed connection.
Historical `TIMESTAMP` rows are also converted explicitly from the effective
session timezone into the channel timezone, so an automatic driver reconnect
cannot silently reclassify them. Past and future daylight-saving transitions
remain correct.

## Catalogue and evidence

| Family | Achievements | Durable evidence |
| --- | --- | --- |
| Messages | First Steps 1; Chatterbox 1,000; Megaphone 10,000; Icon 50,000; Legend 150,000 | Real public/action rows in `CHANNEL_LOG` |
| Night, 00:00–05:59 | Night Owl 50; Midnight Regular 250; Creature of the Night 1,000; The Witching Hour 5,000 | Historical messages converted to channel civil time |
| Morning, 06:00–08:59 | Early Bird 50 | Historical messages converted to channel civil time |
| Vocabulary | Wordsmith 1,000; Polyglot 7,500 | Distinct words reported by `!wordcount` |
| Karma | Karma Star +50; Karma Legend +250; Gift Giver 250 positive votes | Channel karma state; durable per-vote giver counter |
| Community | Archivist 10 / Master Archivist 50 quotes; Lorekeeper 10 / Encyclopedist 50 factoids; Curator 10 of each | Current `QUOTES` and `FACTOID` rows, not blind increments |
| Trivia | Trivia Rookie 10; Trivia Champion 300; Trivia Sniper at most 2.000 seconds | Durable correct-answer counter and high-resolution response time |
| Activity | On a Roll 7; Habit Formed 30; Streak Master 100; Eternal Flame 365 days | Best consecutive local-calendar run observed by `!streak` |
| Comeback | Welcome Back 7; Long Time No See 30; The Return 90; Phoenix Rising 365 days | Pre-JOIN `USER_SEEN` absence, consumed after the user speaks |
| Duels | Duel Warrior 10; Duel Master 150; Underdog after 8 consecutive losses | Durable win count; live consecutive-loss state |
| Social tools | Star Gazer 30; Matchmaker 25; Quote Detective 20; Quote Master 150; Mood Reader 30 | Durable successful-use counters per channel |
| Network breadth | Polyphony on 8 channels | Distinct public channels with real message/action rows |

The Witching Hour, Eternal Flame and Phoenix Rising are secret until unlocked.
Trivia Sniper and Underdog are event conditions, so they do not expose a
fabricated percentage before the qualifying event.

## Accuracy rules

- Only `public` and `action` log events count as speech.
- Message-derived identity matching is bounded to aliases attached to the same
  durable achievement profile.
- State-backed counters are monotonic: a purge or smaller rolling observation
  cannot revoke already established merit.
- Hour-band unlocks are only evaluated while the triggering message is inside
  that same channel-local band. A daytime message cannot announce Night Owl.
- Gift Giver increments durable progress directly, so a restart cannot reset or
  stall the total behind an in-memory ring buffer.
- Trivia Sniper uses a high-resolution elapsed duration and the advertised
  inclusive `<= 2.000 s` boundary.
- Invalid observations do not unlock achievements. Database-derived community
  achievements are recalculated from their authoritative tables.

Thresholds can be overridden under `[achievements]` with uppercase IDs, for
example `TRIVIA_CHAMPION=200`. Existing unlocks are not revoked merely because
a threshold is later raised.

## Operator checks

After an upgrade:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
perl -I. -c mediabot.pl
perl t/test_commands.pl --progress --filter 'achievement|timezone'
```

Inspect the application log first if an asynchronous achievement scan is
retried or dropped. Missing MariaDB timezone data is reported explicitly rather
than silently classifying UTC rows as local civil time.
