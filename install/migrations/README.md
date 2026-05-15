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

## Current important migration

```text
mediabot_fun_commands_migration_20260512.sql
20260515_claude_chanset.sql
```

This migration adds schema support for newer fun/user commands, including:

```text
REMINDERS
BOT_ALIAS
KARMA
```

These tables are used by reminder, alias and karma-related code paths.

## Recommended application method

Use the interactive SQL client and explicit UTF-8 settings:

```bash
mysql -u root -p --default-character-set=utf8mb4
```

Then inside the SQL client:

```sql
SET NAMES utf8mb4;
USE mediabot;
SOURCE /home/mediabot/mediabot_v3/install/migrations/mediabot_fun_commands_migration_20260512.sql;
```

Afterwards:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

## Rule

Never start an upgraded bot against an old database without running the schema drift checker first.
