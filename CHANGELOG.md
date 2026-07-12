# Changelog — Mediabot v3

All notable changes to Mediabot v3 are documented here.

Versioning follows the project rule: odd minor versions are stable releases,
even minor versions are development lines. The upcoming **3.3** is the next
stable target, currently prepared on the `3.2dev` development line.

---

## [3.3] — unreleased (target)

> Prepared on `3.2dev`. The stable tag is created only after full validation
> on the production instance and explicit sign-off. Nothing below changes the
> database schema unless a migration is explicitly listed under "Migrations".

### Added — everyday user features

- **`!tell <nick> <message>`** — leave a message that is delivered when the
  recipient next joins or speaks on the channel.
- **Command suggestions** — unknown public commands can offer a guarded
  “Did you mean?” suggestion, with a per-channel `DidYouMean` opt-out.
- **Shared factoids** — `!learn`, `!whatis`, `!forget`, `!factoids`,
  `!factoid`, and the quiet `?keyword` shortcut provide persistent
  channel-scoped knowledge with authorship, hit counts and top/detail views.
- **`!convert`** — offline unit conversion for length, mass, temperature,
  volume, speed and decimal/binary data units.
- **`!stats` achievements** — user statistics can include the number of
  unlocked channel achievements when available.

### Added — channel engagement

- **`!onthisday` / `!otd`** — resurface what happened on the channel on this
  calendar day in past years (per-year stats, most active nick, a
  representative message). Gated by the `OnThisDay` chanset.
- **`!onthisday [MM-DD]`** — target a specific calendar date instead of today
  (e.g. `!onthisday 12-25`). Fully parameterised SQL.
- **Daily "on this day" digest** — opt-in automatic recap posted once a day to
  channels with the `+OnThisDayDigest` chanset, at the hour configured by
  `ONTHISDAY_DIGEST_HOUR` (default 12, set `-1` to disable).
- **`!topquote` / `!halloffame`** — channel hall of fame: the most-recalled
  quotes, ranked by a new `hits` counter that increments whenever a quote is
  shown by id or at random.
- **`!milestone` / `!milestones`** — channel milestones: total messages logged,
  the last round milestone passed, the next one with progress and an ETA based
  on the recent daily rate, plus the channel's logging age.

### Improved

- **`!seen`** — the stored last message is now sanitised for display (IRC
  colour/formatting/control codes stripped, length bounded) and enriched with a
  recent-activity hint (`[N msg in last 24h]`).
- **`!mood`** — beyond sentiment and energy, it now shows a "pulse" line: the
  top talkers of the last 60 minutes and today's busiest hour.
- **Help system** — dispatch/help consistency guard, cleaned-up categories, a
  compact non-truncated welcome screen, working `help <category>`, and detailed
  listings for small categories.
- **URL handling** — richer link previews with details for Apple Music
  (JSON-LD), X/Twitter (tweet text, likes, retweets), Facebook and Instagram;
  sub-second fast paths that avoid launching a browser where possible.
- **`!recap ai`** — the AI summary is now capped in the number of emitted lines
  to prevent flooding, with a truncation notice beyond the cap.

### Fixed

- URL compact counter rendered `1000k` instead of `1M` at the 999,999 boundary.
- Facebook/URL previews: hex HTML entities (`&#x…;`) were not decoded, leaking
  raw encoded text; now handled for every URL handler.
- Chromium fallback crashed with SIGTRAP on some hosts; fixed with a unique
  throwaway profile directory and crash-reporter flags.
- Facebook apostrophes truncated link titles (single-quote capture); fixed with
  paired-quote extraction.
- `!milestone` lacked a per-nick cooldown despite scanning the channel log;
  aligned with `!mood` / `!onthisday`.
- `!topquote` / `!halloffame` were mis-categorised in the help index; now grouped
  with the other quote commands.
- `!mood` had no `$dbh` guard and no cooldown; both added.

### Migrations

The authoritative complete order for existing databases is maintained in
`install/migrations/README.md`. Do not infer an upgrade plan from this summary
alone; generate and review it against the real instance configuration.

Recent July release migrations, all idempotent and non-destructive:

- `20260706_channel_log_channel_ts.sql` — composite channel/time log index.
- `20260707_channel_report_chanset.sql` — per-channel report gate.
- `20260707_didyoumean_chanset.sql` — command-suggestion gate.
- `20260707_factoid.sql` — persistent shared factoids.
- `20260707_factoids_chanset.sql` — per-channel factoid gate.
- `20260708_onthisday_chanset.sql` — `OnThisDay` chanset.
- `20260708_onthisday_digest_chanset.sql` — `OnThisDayDigest` chanset (opt-in).
- `20260710_quotes_hits.sql` — `QUOTES.hits` recall counter + composite index.

### Hardening / internal

- Boot-time integrity check turns mid-traffic method-resolution failures into a
  clean startup exit.
- bcrypt lazy migration on successful login (no schema change).
- Fresh-install schema and upgrade migrations now carry the same release
  indexes, including `idx_quotes_channel_hits`.
- `check_schema_drift.pl --indexes` compares required reference indexes and
  can generate non-destructive `ADD INDEX` statements for missing indexes.
- `configure` now runs drift checks fail-closed with column types and required
  indexes on the initial check, generated review plan and post-migration check.
- Extensive test suite growth; the offline suite runs green end to end.

---

## [3.1] — stable (previous line)

Baseline stable release preceding the 3.2dev development line. See the git
history for the detailed 3.1 series changes.
