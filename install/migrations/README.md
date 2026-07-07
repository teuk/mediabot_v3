# Mediabot SQL migrations

This directory contains SQL migration files for existing Mediabot databases.

Fresh installs should use:

```text
install/mediabot.sql
```

Existing installations should apply only the missing migrations, then validate with:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

## Current migration order

```text
20260502_channel_ban.sql
20260502_user_seen.sql
mediabot_fun_commands_migration_20260512.sql
20260515_claude_chanset.sql
20260521_trivia_scores_note.sql
20260603_karma_log.sql
20260604_achievement_announce_chanset.sql
20260604_chansets_mb115_mb118.sql
20260706_channel_log_channel_ts.sql
```

The migration set adds channel-ban tracking, user seen/activity tracking, Claude chanset reference data, schema support for newer fun/user commands, and persistent trivia scores and user notes, including:

```text
CHANNEL_BAN
USER_SEEN
REMINDERS
BOT_ALIAS
KARMA
KARMA_LOG
TRIVIA_SCORES
NOTE
CHANSET_LIST entries: AchievementAnnounce, Games
```

These tables and reference-data migrations are used by reminder, alias, karma, karma history, trivia, note-related, achievements and games-related code paths.

## Recommended application method

Use the interactive SQL client and explicit UTF-8 settings:

```bash
mysql -u root -p --default-character-set=utf8mb4
```

Then inside the SQL client:

```sql
SET NAMES utf8mb4;
USE mediabot;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_channel_ban.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_user_seen.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/mediabot_fun_commands_migration_20260512.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260515_claude_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260521_trivia_scores_note.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260603_karma_log.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260604_achievement_announce_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260604_chansets_mb115_mb118.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260706_channel_log_channel_ts.sql;
```

Afterwards:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

## Rule

Never start an upgraded bot against an old database without running the schema drift checker first.
