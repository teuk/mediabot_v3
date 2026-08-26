# Mediabot SQL migrations

This directory contains SQL migration files for existing Mediabot databases.

Fresh installs should use:

```text
install/mediabot.sql
```

Existing installations should first generate and review a migration plan:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration --types --indexes
```

Then apply only the required migrations and validate with:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
```

With `--indexes`, the drift checker compares every index required by
`install/mediabot.sql` and can emit non-destructive `ADD INDEX` statements for
missing non-primary indexes. Extra live-only indexes are intentionally ignored.
Official migration files remain the authoritative, reviewable upgrade path.

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
20260707_channel_report_chanset.sql
20260707_didyoumean_chanset.sql
20260707_factoid.sql
20260707_factoids_chanset.sql
20260708_onthisday_chanset.sql
20260708_onthisday_digest_chanset.sql
20260710_quotes_hits.sql
20260724_lang_chansets.sql
20260816_achievements_db.sql
20260822_rss_feeds.sql
20260823_legacy_schema_reconciliation.sql
20260825_wit_chanset.sql
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
CHANSET_LIST entries: AchievementAnnounce, Games, Wit
ACHIEVEMENT_PROFILE / ACHIEVEMENT_IDENTITY / ACHIEVEMENT_UNLOCK / ACHIEVEMENT_PROGRESS
RSS_FEED / RSS_ITEM
```

These tables and reference-data migrations are used by reminder, alias, karma, karma history, trivia, note-related, achievements and games-related code paths.

## Released migration immutability

Migration files that shipped in a stable release are append-only history: do
not edit or remove them after publication. Fixes belong in a new migration.
The Debian 13 stable-upgrade CI gate compares the migration files from Git tag
`3.3` with the current tree by SHA-256 and fails if a released migration was
removed or rewritten.

Migration files added after the stable tag are applied in the exact order
listed in **Current migration order** above, then the live database must pass
`check_schema_drift.pl --strict --types --indexes`.

For automation, `install/db_migrate.sh` accepts a private MySQL option file:

```bash
install/db_migrate.sh \
  --defaults-extra-file /root/.mediabot-mysql.cnf \
  mediabot \
  install/migrations/<migration>.sql
```

The file must be a regular non-symlink file with no group/other permissions.
Without that option, the helper preserves its historical interactive `-p`
prompt.

## Long-lived database reconciliation

`20260823_legacy_schema_reconciliation.sql` is a compatibility migration for
installations whose database predates the canonical 3.3 schema history. It is
not needed to make a fresh install correct: the fresh schema and the normal
3.3-to-current migration path are already equivalent.

The migration is fail-closed. It checks narrowing/index/FK preconditions before
DDL, preserves rows and `USER.hostmasks_legacy`, normalizes historical
utf8mb3/latin1 table defaults to `utf8mb4_unicode_ci`, restores canonical
column/index/FK definitions, and deliberately keeps unrelated extra indexes.

For a long-lived production database, rehearse this migration on a clone and
make a database backup before applying it to the real instance.

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
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_channel_report_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_didyoumean_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_factoid.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_factoids_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260708_onthisday_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260708_onthisday_digest_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260710_quotes_hits.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260724_lang_chansets.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260816_achievements_db.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260822_rss_feeds.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260823_legacy_schema_reconciliation.sql;
```

Afterwards:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
```

## Index note

Fresh installs receive the current indexes from `install/mediabot.sql`.
Existing installations must apply the idempotent index migrations, notably:

```text
20260706_channel_log_channel_ts.sql
20260710_quotes_hits.sql
```

`check_schema_drift.pl` compares required reference indexes when `--indexes` is supplied. Extra live-only indexes are intentionally ignored.

## Rule

Never start an upgraded bot against an old database without running the schema drift checker first.
