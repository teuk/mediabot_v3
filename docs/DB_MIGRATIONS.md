# Mediabot database migrations

This document explains how to keep an existing Mediabot database aligned with the schema shipped in `install/mediabot.sql`.

## Fresh install

For a fresh installation, use the normal installer/configuration flow.

The reference schema is:

```text
install/mediabot.sql
```

After the database has been created, validate it with:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

A clean result should end with:

```text
Schema is in sync with the live database. No drift detected.
```

## Existing installation / upgrade

For an existing database, never assume that new tables are present just because the code was updated.

Recommended upgrade flow:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
perl tools/check_schema_drift.pl --conf=mediabot.conf
```

If drift is detected, inspect `install/migrations/` and apply the missing migration files.

Use the interactive MySQL/MariaDB client with an explicit charset:

```bash
mysql -u root -p --default-character-set=utf8mb4
```

Then inside the SQL client:

```sql
SET NAMES utf8mb4;
USE mediabot;
SOURCE /home/mediabot/mediabot_v3/install/migrations/mediabot_fun_commands_migration_20260512.sql;
```

Then run the checker again:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

## Undernet / mediabot3

For the Undernet instance:

```text
/home/mediabot/mediabot3
/home/mediabot/mediabot3/mbundernet.conf
```

Check schema drift with:

```bash
cd /home/mediabot/mediabot3 || exit 1
perl /home/mediabot/mediabot_v3/tools/check_schema_drift.pl \
  --conf=/home/mediabot/mediabot3/mbundernet.conf \
  --schema=/home/mediabot/mediabot_v3/install/mediabot.sql \
  --strict
```

Apply migrations before starting a newly updated bot if the checker reports missing tables or columns.

## Useful commands

Report-only mode:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf
```

Strict mode for automation:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

Preview SQL for missing tables/columns only:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration
```

Also compare normalized column definitions:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --types
```

Ignore extra legacy tables/columns:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --ignore-extra
```

## Safety rules

Do not apply generated SQL blindly.

The checker deliberately does not generate `DROP TABLE` or `DROP COLUMN` statements.

Before applying migrations to a production database:

1. stop the bot if the migration touches tables used at runtime;
2. create a database backup;
3. apply migrations with `SET NAMES utf8mb4`;
4. run `tools/check_schema_drift.pl --strict`;
5. only then restart the bot.
