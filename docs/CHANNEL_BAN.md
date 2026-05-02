# Mediabot v3 Channel Ban System

Mediabot v3 supports persistent channel bans with optional duration, ban levels, kickban support, manual unban, automatic expiration and database history.

This feature is designed to behave like a real IRC channel administration tool, not just a simple `KICK`.

A kick alone does not prevent a user from coming back. A ban does.

---

## Commands

The public IRC commands are:

```text
bans [#channel]
ban [#channel] <nick|mask> [duration] [level] [reason]
kickban [#channel] <nick|mask> [duration] [level] [reason]
kb [#channel] <nick|mask> [duration] [level] [reason]
unban [#channel] <id|mask>
```

`kb` is an alias for `kickban`.

If the channel is omitted, Mediabot uses the current channel when the command is issued from a channel.

---

## Required channel level

The minimum channel level required to use ban commands is:

```text
75
```

This follows an Undernet-inspired model.

The ban level defaults to the actor channel level, with a minimum of 75.

Examples:

```text
ban #test *!*bad@example.org 10m
ban #test *!*bad@example.org 10m 75 reason here
kickban #test BadNick 1h 75 repeated abuse
```

A user cannot set a ban level higher than their own channel level.

For example, a user with level `100` cannot create a ban with level `500`.

---

## Ban levels

Each stored ban has a `ban_level`.

This level is used for permission checks, especially when removing a ban.

A user can only remove a ban if their channel level is greater than or equal to the ban level.

This prevents lower-level users from removing higher-level bans.

---

## Durations

Accepted duration values:

```text
10m    ten minutes
2h     two hours
3d     three days
1w     one week
30     thirty minutes
perm   permanent
permanent
never
```

An omitted duration means permanent.

A duration of `0` is intentionally not treated as permanent in the parser tests. Use `perm`, `permanent`, `never`, or omit the duration for a permanent ban.

---

## Ban masks

Mediabot accepts explicit masks such as:

```text
*!*user@hostname.com
*!*user@192.168.1.1
*!*user@*.wanadoo.fr
*!user@some.host.net
nick!user@host
```

If a plain nick is provided, Mediabot tries to resolve the latest known hostmask from `CHANNEL_LOG`.

Example:

```text
kickban #test BadNick 10m 75 test kickban
```

If `BadNick` has a known hostmask in channel logs, Mediabot builds a safer mask and applies it.

---

## Dangerous masks

Mediabot refuses broad or dangerous masks such as:

```text
*!*@*
*!*@*.*
*!*
*
```

The goal is to avoid accidental mass bans.

The mask must contain a useful fixed host part.

---

## What `ban` does

The `ban` command:

```text
ban #test *!*bad@example.org 10m 75 reason here
```

does:

```text
MODE #test +b *!*bad@example.org
INSERT INTO CHANNEL_BAN (...)
```

The user is not kicked.

---

## What `kickban` does

The `kickban` command:

```text
kickban #test BadNick 10m 75 reason here
```

does:

```text
MODE #test +b resolved-mask
KICK #test BadNick :reason
INSERT INTO CHANNEL_BAN (...)
```

If the target is an explicit mask and not a nick, Mediabot can apply the ban but cannot kick a specific user.

---

## What `unban` does

Unban can target either the ban id or the mask.

```text
unban #test 42
unban #test *!*bad@example.org
```

It does:

```text
MODE #test -b mask
UPDATE CHANNEL_BAN
  SET active = 0,
      removed_by = ...,
      removed_by_nick = ...,
      removed_at = NOW(),
      remove_reason = 'manual unban'
```

The historical row remains in the database.

---

## What `bans` does

The `bans` command lists active bans known by Mediabot:

```text
bans #test
```

Example output:

```text
#42 *!*bad@example.org level=75 by=teuk expires=2026-05-02 12:00:00 reason=test ban
Showing 1/1 active bans on #test.
```

---

## Automatic expiration

Temporary bans are automatically expired by the bot.

The periodic timer checks active bans whose `expires_at` is in the past.

For each expired ban, Mediabot does:

```text
MODE #channel -b mask
UPDATE CHANNEL_BAN
  SET active = 0,
      removed_by_nick = 'system',
      removed_at = NOW(),
      remove_reason = 'expired'
```

If `MODE -b` fails, the ban remains active and will be retried later.

---

## Database table

The persistent table is:

```text
CHANNEL_BAN
```

Important fields:

```text
id_channel_ban
id_channel
mask
ban_level
reason
created_by
created_by_nick
created_at
expires_at
active
removed_by
removed_by_nick
removed_at
remove_reason
source
```

The table has foreign keys to:

```text
CHANNEL(id_channel)
USER(id_user)
```

---

## Migration

The migration file is:

```text
install/migrations/20260502_channel_ban.sql
```

Recommended import method:

```bash
mysql --default-character-set=utf8mb4 -u root mediabotv3
```

Then inside MariaDB:

```sql
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET CHARACTER SET utf8mb4;

SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_channel_ban.sql;
```

This is preferred over shell redirection because the charset path is explicit and reproducible.

---

## Fresh install

The `CHANNEL_BAN` table is also included in:

```text
install/mediabot.sql
```

A fresh install should therefore create the table directly.

The migration exists for already-installed databases.

---

## Tests

Relevant tests:

```text
t/cases/06_channel_ban.t
t/cases/09_channel_ban_commands.t
```

Run only ChannelBan helper tests:

```bash
LANG=C.UTF-8 LC_ALL=C.UTF-8 perl t/test_commands.pl --filter channel_ban --verbose
```

Run command integration tests:

```bash
LANG=C.UTF-8 LC_ALL=C.UTF-8 perl t/test_commands.pl --filter channel_ban_commands --verbose
```

Run all tests:

```bash
LANG=C.UTF-8 LC_ALL=C.UTF-8 perl t/test_commands.pl --verbose
```

---

## Safety checklist

Before committing changes to this area:

```bash
perl -I. -c Mediabot/ChannelBan.pm
perl -I. -c Mediabot/ChannelCommands.pm
perl -I. -c Mediabot/Mediabot.pm
perl -I. -c mediabot.pl

LANG=C.UTF-8 LC_ALL=C.UTF-8 perl t/test_commands.pl --filter 'channel_ban|channel_ban_commands' --verbose
```

Then test on IRC with a development channel:

```text
bans #test
ban #test *!*channelban-test@example.org 1m 75 test expiration
bans #test
unban #test <id>
kickban #test SomeNick 1m 75 test kickban
```

---

## Notes for maintainers

This feature touches both IRC-side behavior and database state.

When editing it, keep these checks in mind:

```text
- A command-level permission check must happen before MODE +b or MODE -b.
- A dangerous mask must be rejected before any IRC command is sent.
- The database state must stay consistent with the IRC action.
- Expiration should only mark a ban inactive after MODE -b succeeds.
- Fresh installs and migrations must stay aligned.
```

The most sensitive files are:

```text
Mediabot/ChannelBan.pm
Mediabot/ChannelCommands.pm
Mediabot/Mediabot.pm
mediabot.pl
install/migrations/20260502_channel_ban.sql
install/mediabot.sql
t/cases/06_channel_ban.t
t/cases/09_channel_ban_commands.t
```
