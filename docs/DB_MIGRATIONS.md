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
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_channel_ban.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260502_user_seen.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/mediabot_fun_commands_migration_20260512.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260515_claude_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260521_trivia_scores_note.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260603_karma_log.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260604_achievement_announce_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260604_chansets_mb115_mb118.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260706_channel_log_channel_ts.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_channel_report_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_didyoumean_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_factoids_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260708_onthisday_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_factoid.sql;
```

Then run the checker again:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict
```

## Migration order

The authoritative, complete and ordered list of migrations is maintained in
`install/migrations/README.md`. For an existing database, apply migrations in
this order unless a later release note says otherwise:

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
20260707_channel_report_chanset.sql
20260707_didyoumean_chanset.sql
20260707_factoid.sql
20260707_factoids_chanset.sql
20260708_onthisday_chanset.sql
```

A fresh install uses `install/mediabot.sql` directly and must NOT apply this
historical stack. Structure migrations are verified by
`tools/check_schema_drift.pl`; reference-data migrations (such as
`20260515_claude_chanset.sql` or `20260604_chansets_mb115_mb118.sql`) are not
covered by the drift checker and must still be applied when upgrading.

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

## CHANNEL_LOG composite index (20260706)

`20260706_channel_log_channel_ts.sql` adds a composite index
`idx_channel_log_channel_ts (id_channel, ts)` to speed up the hot queries that
filter by channel then bound or sort by time (`m check` / stats, achievements
hourband, period reports). It is idempotent: a guarded stored procedure checks
`information_schema.STATISTICS` and only creates the index if missing, so it can
be replayed safely. It removes no existing index, adds no table or column, and
touches no data.

Note: once the composite `(id_channel, ts)` exists, the standalone
`idx_channel_log_id_channel (id_channel)` becomes a left-prefix duplicate. It is
kept for now (removing an index is a separate, explicitly-approved decision per
the 3.3 direction); it can be dropped later if write cost matters. Measure with
`tools/measure_channel_log.pl --conf=mediabot.conf` before and after applying
the migration to confirm the optimiser picks the composite index.

## Safety rules

Do not apply generated SQL blindly.

The checker deliberately does not generate `DROP TABLE` or `DROP COLUMN` statements.

Before applying migrations to a production database:

1. stop the bot if the migration touches tables used at runtime;
2. create a database backup;
3. apply migrations with `SET NAMES utf8mb4`;
4. run `tools/check_schema_drift.pl --strict`;
5. only then restart the bot.

Note: `tools/check_schema_drift.pl` checks schema structure. Reference data migrations such as `20260515_claude_chanset.sql` must still be applied when upgrading an existing database.
