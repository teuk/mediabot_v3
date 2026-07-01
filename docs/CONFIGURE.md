# Mediabot v3 configuration wizard

`./configure` is the supported configuration and installation entry point for
both fresh and existing Mediabot v3 installations.

The wizard uses `mediabot.sample.conf` as its source of truth. It does not keep a
second hand-written list of settings.

## Safety model

The configuration flow:

- never evaluates configuration values;
- never enables Partyline eval;
- writes `mediabot.conf` with mode `0600`;
- hides passwords from logs and process arguments;
- creates timestamped backups before changing an existing config;
- replaces files through an atomic rename;
- preserves existing values and custom keys;
- normalizes duplicate active keys and sections;
- never applies generated drift SQL automatically.

The dangerous setting remains:

```ini
PARTYLINE_EVAL_ENABLED=0
```

If an existing config has it enabled, the wizard warns and proposes disabling
it. A strict final audit refuses to call such a configuration safe.

## Fresh installation

Run as the dedicated Mediabot user:

```bash
cd /home/mediabot/mediabot_v3 || exit 1
./configure
```

The fresh path:

1. generates a complete config from `mediabot.sample.conf`;
2. applies dynamic paths for PID, log and Partyline status files;
3. creates the database and application DB user through `db_install.sh`;
4. installs Perl dependencies;
5. configures the IRC network, server and console channel;
6. runs the database schema/reference-data drift checker;
7. performs a strict final config audit.

The generated config contains every active key from the sample, including safe
defaults for retention, reports, Hailo activity, metrics, antiflood, Chromium,
OpenAI, Anthropic and radio integrations.

Deployment-specific options such as DCC public IP/range and plugin loading stay
commented until explicitly configured.

## Existing installation

Running `./configure` against an existing `mediabot.conf` is non-destructive by
default.

The wizard:

1. creates a backup under `config-backups/`;
2. merges missing sample defaults;
3. keeps current values and secrets;
4. preserves custom keys and custom sections;
5. normalizes duplicate active keys;
6. offers a database drift check;
7. offers, but does not force, dependency and IRC/network review.

Example:

```bash
./configure --config /home/mediabot/mediabot_v3/mediabot.conf
```

## Database drift workflow

For an existing database, the wizard runs:

```bash
perl tools/check_schema_drift.pl --conf=mediabot.conf
```

If drift is found, it writes a review report under `run/` and lists the official
files in `install/migrations/`.

Generated SQL is **never** applied automatically.

The optional guided selector can only run an official migration after an
explicit selection and confirmation. The drift checker is then run again in
strict mode.

Run only the drift workflow with:

```bash
./configure --config mediabot.conf --drift-only
```

## Synchronize config only

To add missing defaults, normalize duplicate keys and create a backup without
touching the database or IRC records:

```bash
./configure --config mediabot.conf --sync-only
```

## Useful options

```text
-c, --config FILE   choose the config path
--sync-only         merge/audit config and stop
--skip-db           skip database creation and drift checks
--skip-cpan         skip Perl dependency installation
--drift-only        run only the existing-database drift workflow
-y, --yes           accept safe default answers where supported
-s FILE             legacy server configuration mode
-l                  list servers with legacy -s mode
```

## Atomic configuration engine

The core engine can be used directly for diagnostics:

```bash
perl install/configure_config.pl \
  --sample mediabot.sample.conf \
  --config mediabot.conf \
  --mode audit \
  --strict
```

Read one setting without sourcing or evaluating the file:

```bash
perl install/configure_config.pl \
  --config mediabot.conf \
  --get mysql.MAIN_PROG_DDBNAME
```

Do not `source` or `eval` `mediabot.conf`. It is an INI file, not a shell script.
