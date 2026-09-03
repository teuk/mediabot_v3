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
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
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
perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration --types --indexes
```

Review the generated plan before applying anything. It can propose missing
tables, columns, required indexes and `CHANSET_LIST` rows, but it deliberately
does not generate destructive `DROP` statements. With `--indexes`, required
reference indexes are compared by name, uniqueness and ordered columns; extra
live-only indexes are intentionally ignored. Inspect the ordered migration list
below and apply every required structure and reference-data migration for the
target database.

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
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_factoid.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260707_factoids_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260708_onthisday_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260708_onthisday_digest_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260710_quotes_hits.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260724_lang_chansets.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260816_achievements_db.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260822_rss_feeds.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260823_legacy_schema_reconciliation.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260825_wit_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260827_spark_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260827_vdm_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260827_danstonchat_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260828_spark_action_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260902_hailo_policy_chansets.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260902_gemini_chanset.sql;
SOURCE /home/mediabot/mediabot_v3/install/migrations/20260903_fullop_chanset.sql;
```

Then run the checker again:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
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
20260708_onthisday_digest_chanset.sql
20260710_quotes_hits.sql
20260724_lang_chansets.sql
20260816_achievements_db.sql
20260822_rss_feeds.sql
20260823_legacy_schema_reconciliation.sql
20260825_wit_chanset.sql
20260827_spark_chanset.sql
20260827_vdm_chanset.sql
20260827_danstonchat_chanset.sql
20260828_spark_action_chanset.sql
20260902_hailo_policy_chansets.sql
20260902_gemini_chanset.sql
20260903_fullop_chanset.sql
```

A fresh install uses `install/mediabot.sql` directly and must NOT apply this
historical stack. `tools/check_schema_drift.pl` checks tables, columns, optional
normalized types and missing `CHANSET_LIST` rows. With `--indexes`, it also
compares every required reference index. It does not infer arbitrary
non-`CHANSET_LIST` reference data, so those data migrations must still be
reviewed and applied when upgrading.

## Native RSS persistence (20260822)

`20260822_rss_feeds.sql` adds the persistent storage used by Mediabot's native
per-channel RSS/Atom feature:

```text
RSS_FEED
RSS_ITEM
```

`RSS_FEED` stores channel subscriptions and polling metadata. `RSS_ITEM` stores
durable item keys used for first-fetch baselines and duplicate suppression.
The migration is idempotent and does not enable polling by itself; command
routing and asynchronous fetching are separate runtime steps.

For an existing installation, back up the configured database before applying
the migration, then validate the RSS schema delta with the normal drift checker.
Historical unrelated drift must be reviewed separately rather than silently
rewritten as part of the RSS rollout.

## Long-lived schema reconciliation (20260823)

`20260823_legacy_schema_reconciliation.sql` is a compatibility migration for
databases whose history predates the canonical stable 3.3 schema. A fresh
installation does not need historical migrations, and the normal real
3.3-to-current migration path is already validated to converge with a current
fresh database.

The reconciliation migration is intentionally fail-closed. Before narrowing
numeric types, restoring unique prefix indexes or adding foreign keys, it
checks the existing data for negative/out-of-range values, duplicate key
prefixes, zero dates and orphan references. Unsafe data stops the migration
instead of being silently rewritten.

The migration also normalizes audited historical table defaults/text columns to
`utf8mb4_unicode_ci`, restores canonical required indexes and foreign-key
names/rules, and preserves unrelated extra indexes that may be local performance
tuning.

`USER.hostmasks_legacy` is deliberately **not** dropped. Long-lived databases
may still contain compatibility values not represented by `USER_HOSTMASK`; any
future removal requires a separately proven data migration.

For a long-lived database, rehearse this migration on a clone first and take a
database backup before applying it to the real instance. After application,
validate with:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes --allow-extra-column USER.hostmasks_legacy
```

The compatibility allowance is deliberately exact: only
`USER.hostmasks_legacy` is accepted. Any other extra table or column remains
schema drift and still fails strict validation. The broader `--ignore-extra`
option remains available for explicit diagnostics, but is not the MB695
release-validation path.

## Useful commands

Report-only mode:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf
```

Strict mode for automation:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
```

Preview SQL for missing tables, columns, required indexes and
`CHANSET_LIST` rows:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --generate-migration --types --indexes
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

## QUOTES hall-of-fame index (20260710)

`20260710_quotes_hits.sql` adds `QUOTES.hits` and the composite index
`idx_quotes_channel_hits (id_channel, hits)`. The same index is present in the
fresh reference schema, so fresh installs and upgraded databases have the same
query support.

The drift checker compares these indexes when `--indexes` is supplied.
Verify the two release-critical composite indexes explicitly as an independent
certification check:

```sql
SHOW INDEX FROM CHANNEL_LOG WHERE Key_name = 'idx_channel_log_channel_ts';
SHOW INDEX FROM QUOTES      WHERE Key_name = 'idx_quotes_channel_hits';
```

## Achievements DB persistence (20260816)

`20260816_achievements_db.sql` moves achievement unlocks and progress from the
release-local `var/achievements.json` file into MariaDB.

The model separates a durable per-channel profile from the IRC identities that
have been observed for it:

```text
ACHIEVEMENT_PROFILE
  └─ ACHIEVEMENT_IDENTITY  (nick + user@host + channel aliases)
  ├─ ACHIEVEMENT_UNLOCK
  └─ ACHIEVEMENT_PROGRESS
```

Identity matching is intentionally conservative. Exact triplets win; a known
registered `USER.id_user` is authoritative; an exact `user@host` can follow a
nick change; and the same nick can follow a host variation only when the ident
or host still matches. Ambiguous nick-only collisions are not merged.

After the migration is applied, the first Mediabot startup imports any existing
legacy JSON state idempotently and renames the source file to
`achievements.json.migrated-<timestamp>`.

### MB646 operational upgrade runbook

This procedure is for an **existing** Mediabot instance. A fresh installation
uses `install/mediabot.sql` and must not replay the historical migration stack.

Before changing anything, run the Doctor against the configuration actually used
by the instance:

```bash
perl tools/mediabot_doctor.pl --conf=mediabot.conf
```

Before MB646 is applied, completely absent achievement tables are a supported
legacy **runtime** state: Mediabot keeps using JSON fallback. The Doctor reports
that fallback, but its delegated schema-drift check also sees the four required
MB646 tables as missing. Therefore an otherwise healthy pre-MB646 instance is
expected to finish with an overall `UNSAFE` verdict until the migration is
applied. JSON fallback means the old runtime can still operate; it does **not**
mean that updating/restarting the new code against the unmigrated database is
safe.

A **partial** MB646 schema is different again and must be investigated rather
than treated as a normal upgrade starting point.

For the migration itself:

1. stop the Mediabot instance so achievement state cannot change during the
   transition;
2. back up the configured database;
3. connect to that database with `utf8mb4` enabled;
4. apply `install/migrations/20260816_achievements_db.sql`;
5. while the bot is still stopped, verify schema and migration state;
6. restart the instance;
7. run the Doctor again against the live instance.

The pre-restart checks can be performed with:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf --strict --types --indexes
perl tools/mediabot_doctor.pl --conf=mediabot.conf --domain database --domain migrations
```

Then restart the instance using its normal systemd/deployment contract and run:

```bash
perl tools/mediabot_doctor.pl --conf=mediabot.conf
```

On the first DB-backed startup, Mediabot imports legacy achievement state
transactionally. If the DB is still empty it can merge the live JSON file with
compatible archived releases from the **same deployment family**:

```text
<root>.NNN
<root>.old.YYYYMMDD_HHMMSS
```

Sibling deployment families are deliberately ignored. For example, an instance
running from `mediabot3` must not import achievement state from
`mediabot_v3.*`.

Only the live legacy JSON file is renamed after a successful import:

```text
var/achievements.json
→ var/achievements.json.migrated-<timestamp>
```

Historical archive files are left untouched. If the import fails, its database
transaction is rolled back and the live JSON is not archived as migrated.

For an instance whose MB646 tables are already populated, startup does not
repeat the historical archive-family scan. Any live legacy JSON still present
can still be merged idempotently; otherwise MariaDB simply remains the source
of truth.

## Debian 13 stable-upgrade CI gate

The Debian 13 workflow now validates the database upgrade boundary from the
actual stable `3.3` Git tag to the current development tree.

The gate deliberately does **not** maintain a hand-written "3.3 schema"
fixture. Instead it exports `install/mediabot.sql` and the migration inventory
from Git tag `3.3`, creates a real MariaDB database from that released schema,
and first requires the current strict drift checker to detect that the stable
database is behind:

```text
stable 3.3 schema
    -> current strict drift check must return drift
```

It then compares the migration inventories. A migration already present in the
stable tag must still exist and its SHA-256 must be unchanged. New migration
files are selected from the current tree and ordered by their exact entries in
`install/migrations/README.md`.

Each post-3.3 migration is applied through the real helper:

```bash
install/db_migrate.sh \
  --defaults-extra-file /path/to/private-mysql.cnf \
  mediabot_upgrade \
  install/migrations/<migration>.sql
```

The private option file is mode `0600`; credentials are therefore not placed on
the command line. The historical interactive form remains supported for human
operators:

```bash
install/db_migrate.sh mediabot install/migrations/<migration>.sql root
```

After all post-3.3 migrations, the current checker must pass:

```bash
perl tools/check_schema_drift.pl --strict --types --indexes
```

This is an automated database-upgrade proof. It does not replace the final
manual upgrade rehearsal against a backed-up real instance, nor the separate
systemd/IRC runtime acceptance checks.

## Safety rules

Do not apply generated SQL blindly.

The checker deliberately does not generate `DROP TABLE` or `DROP COLUMN` statements.

Before applying migrations to a production database:

1. stop the bot if the migration touches tables used at runtime;
2. create a database backup;
3. apply migrations with `SET NAMES utf8mb4`;
4. run `tools/check_schema_drift.pl --strict --types --indexes`;
5. only then restart the bot.

Note: `tools/check_schema_drift.pl` checks schema structure. Reference data migrations such as `20260515_claude_chanset.sql` must still be applied when upgrading an existing database.
