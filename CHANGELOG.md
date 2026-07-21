# Changelog — Mediabot v3

All notable changes to Mediabot v3 are documented here.

Versioning follows the project rule: odd minor versions are stable releases
and even minor versions are development lines. **3.3** is the current stable
release. Development after this release continues on the `3.4dev` line.

---

## [Unreleased] — 3.4dev

### Added — LUSERS visibility (mb544)

- The LUSERS details are now first-class debug material: every numeric that
  yields values logs one level-3 line with its key=value pairs (and the
  periodic/manual refresh requests log at level 3 too), the parsed values
  feed a core cache available even without the Metrics system, and a new
  partyline command `.lusers` shows the network snapshot (users/max/
  channels/servers/operators + age); `.lusers refresh` requests fresh
  numerics immediately and resynchronizes the periodic throttle.

### Added — network stats and overview dashboard (mb543)

- **LUSERS network gauges**: the 251/252/254/265/266 numerics now feed five
  gauges (mediabot_network_users, _users_max, _channels, _servers,
  _operators), parsed defensively in the core (unit-tested) with thin
  eval-guarded handlers. A throttled periodic LUSERS refresh keeps them
  current after the connection burst (main.LUSERS_REFRESH, default 300s,
  bounded 60-3600, 0 disables).
- **Network overview dashboard**
  (contrib/grafana/grafana_mediabot_overview_v1.json), matching the 3.3
  social-preview look: a compact 3-unit-high top stats row (bots up, IRC
  connected, network users/channels, joined channels, 24h messages), network
  graphs, per-channel activity, a top-commands donut, per-target drilldown
  via bot/channel template variables, and clickable Grafana/Prometheus
  logos linking to their sites. Guarded by truth tests (every referenced
  series exists, stats-row compactness asserted).

### Fixed — plugin bridge observability and examples (mb543)

- Prometheus event outcomes now account for incomplete contexts and missing
  runners under `other`; the pending-timer gauge is initialized at zero and
  updated as soon as an expired timer releases its slot, even when the deferred
  run is skipped or fails. The timer metric help now lists only emitted
  outcomes. The Grafana lifecycle panel no longer mixes per-second counter
  rates with an absolute gauge on one axis.
- `topicreminder.pl` now adds a stable digest suffix to its readable timer
  names, preventing sanitized or truncated channel names from sharing a timer
  slot while keeping the 64-character protocol bound.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Combined event+timer+config reference** (mb542).
  `examples/topicreminder.pl` re-posts the channel topic after a configurable
  delay (`CONFIG_topic=remind_after=…`, bounded 1-3600, default 300):
  a channel event arms a configured timer whose deferred run rebuilds the
  topic and author from the original envelope — the three arc features in a
  single reference file. It stays silent on the immediate run, arms nothing
  on a cleared topic, and honestly exposes the one-pending-timer-per-name
  semantic (a topic change while a reminder is pending keeps the original
  reminder). Fourteen examples now ship; the cookbook count and citation
  guards were updated accordingly.

### Added — contrib (mb541)

- **Grafana dashboard for the script bridge**
  (`contrib/grafana/grafana_mediabot_scriptbridge_v1.json`): runs by origin
  and result, 24h error ratio, channel-event outcomes with bursts absorbed by
  the anti-storm cooldown, timer lifecycle and the armed-timers gauge.
  Follows the folder conventions (schemaVersion 39, DS_PROMETHEUS variable,
  no hard-coded datasource) and is guarded by truth tests: every PromQL
  series must be declared by the plugin, every declared series must appear
  in a panel, and both READMEs must reference the file.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Prometheus metrics for the script bridge** (mb540). Four series under
  mediabot_scriptbridge_*: runs_total{origin,result} (command/event/timer x
  ok/error), events_total{event,outcome} (accepted/cooldown/self/unrouted/
  other, unknown event names aggregated under "invalid" to bound
  cardinality), timers_total{outcome} (armed/delivered/cancelled) and the
  pending_timers gauge. Strictly best-effort: declared and emitted only when
  the bot's Metrics system is present, no new configuration key, and the
  bridge never depends on observability to function (proven by a
  no-metrics regression test).

### Documentation — plugin bridge (mb538)

- **Script cookbook** (`plugins/scripts/COOKBOOK.md`): task-oriented recipes
  distilled from the shipped examples — minimal contract per language, strict
  input parsing, timer lifecycle, event fields by type, misroute silence,
  per-route configuration with mandatory defaults, and the survival rules.
  Guarded by doc-truth tests: every cited example must exist, every shipped
  example must be cited, the written-out count must match reality, and the
  cited technical invariants (event fields, timer-name charset, tighten-only
  configuration) are cross-checked against the actual sources.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Hot reload of the plugin configuration** (mb537, hardened by mb539).
  `.scriptdryrun reload` re-reads every plugin key (COMMANDS/ROUTES/SCRIPT,
  ACTION_MODE/ALLOW_IRC/APPLY_REQUIRE_SCOPE, EVENTS/EVENT_COOLDOWN,
  CONFIG_<route>) from the in-memory configuration — use it after
  `.reloadconf`/`.rehash`, which reload the file but never touch plugins —
  and lists what changed. Event listeners are resubscribed when the event
  routes change; counters, cooldown windows and armed timers are deliberately
  kept, and an armed timer always fires with the config snapshot it was armed
  with. The key reads are factored into a single shared helper, so any future
  key is hot-reloadable by construction. The fallback SCRIPT path keeps the
  same single-scalar normalization on register and hot reload, including when
  Config::Simple returns an ARRAY value.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Partyline visibility for event cooldown windows** (mb536).
  `.scriptdryrun events` shows the event routes, counters and the
  per-(event, channel) cooldown windows (cooling with remaining time, or
  ready), active windows first, capped at 20 lines with a summary.
  `.scriptdryrun clearevents` resets the cooldown windows only — routes,
  counters and timers are untouched and nothing is ever executed — so an
  operator can unblock a channel after a test or a netsplit instead of
  waiting the window out.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Kick event routing** (mb535). The channel-event whitelist gains `kick`:
  the envelope carries the operator (`nick`), the victim (`kicked`) and the
  reason (`message`); events are suppressed whenever the bot is the kicker or
  the victim, and everything else (opt-in EVENTS route, per-channel cooldown,
  channel-scope guard, dry-run/apply gates) is inherited from mb529.
  `examples/kickwatch.pl` ships as the reference moderation-trace script.
  `nick` remains deliberately unsupported (no single channel, out of the
  scope model — see the mb534 handoff).

### Documentation — plugin bridge handoff (mb534)

- Documented that CONFIG_<route> only applies to ROUTES/EVENTS entries: a
  command served by the SCRIPT fallback has no route name, so its CONFIG_ key
  is ignored (README + sample configuration).
- The Timer actions section now points to both reference implementations
  (remind.pl in Perl, countdown.py in Python).

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Multi-language feature examples** (mb533). The arc's reference examples
  were all Perl; the language x feature matrix is now covered:
  `examples/countdown.py` (Python, routed `pcountdown`) demonstrates timer
  actions plus per-route configuration (`CONFIG_pcountdown=max_seconds=…`,
  tighten-only), and `examples/partwatch.tcl` (Tcl, `EVENTS=part=…`)
  demonstrates channel-event routes and the event-specific `message` field
  (part reason), staying silent on IRC when misrouted. Twelve example scripts ship,
  and the documented sample routes remain covered by the doc-truth guard.

### Fixed — plugin bridge consolidation (mb532)

- The `.scriptdryrun config` partyline reference now documents every key the
  plugin reads: the EVENTS / EVENT_COOLDOWN (mb529) and CONFIG_<route>
  (mb531) blocks were missing since their introduction. A generic test
  contract now cross-checks the reference against the keys actually read by
  the plugin, so a future key cannot be forgotten again.
- `examples/remind.pl` now honors the documented `CONFIG_premind=max_delay=…`
  route configuration (the protocol bounds always win as hard limits; the
  usage reply announces the effective bound).
- `.scriptdryrun status|last` now shows the origin of the last run
  (`command`, `event:<type>` or `timer:<name>`), since mb525/mb529 introduced
  three kinds of runs that were previously indistinguishable.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Per-route configuration in the script envelope** (mb531). Every route —
  command or event — can carry its own configuration through one
  CONFIG_<route> key ("key=value; key2=value2", ';' separated so values may
  contain commas). Keys are [A-Za-z0-9_.-] (max 64), values are capped at
  512 chars (oversized pairs are rejected with a log line, never silently
  truncated) and at most 20 keys per route are kept. The validated map is
  injected into the JSON envelope as data.config only when non-empty, and it
  travels with deferred timer runs. data.config is the only structured
  envelope field (one level deep, scalar values); the flat-envelope contract
  of every other field is unchanged. The shipped greet.pl example reads
  config.welcome, and `.scriptdryrun status` lists configured routes.

- **Shipped event reference examples** (mb530). `examples/greet.pl` (join)
  and `examples/topicwatch.pl` (topic) — the two scripts the mb529 sample
  configuration was already referencing — now actually ship. Both stay
  silent on IRC when routed to an unexpected event, and a new test guard
  verifies that every example route documented in the sample configuration
  exists on disk.

- **Channel-event routing** (mb529). The bridge can now route `join`, `part`
  and `topic` channel events to scripts via the new opt-in `EVENTS` key
  (`EVENTS=join=examples/greet.pl, ...`), one script per event and no
  `SCRIPT` fallback. The core emits `channel_<event>_observed` on the
  EventBus from the JOIN/PART/TOPIC handlers (fail-safe, no-op without
  listeners). Event output passes through the same ACTION_MODE / ALLOW_IRC /
  channel-scope guards as command output, and event scripts may arm timers.
  Guardrails: the bot's own events never trigger scripts, and a per-event,
  per-channel cooldown (`EVENT_COOLDOWN`, default 10s, bounded 1-3600)
  counts and ignores join/part bursts (netsplits) instead of forking on each.
  `.scriptdryrun status` exposes the event map, cooldown and counters.

- **Shipped timer reference example** (mb528). `examples/remind.pl`, routed as
  `premind` in the sample configuration, demonstrates the full timer
  lifecycle: validation and confirmation on the command, one pending reminder
  per nick (protocol-safe timer names derived from the nick), delivery on the
  deferred `timer` event with the message rebuilt from the original args, and
  no timer chaining. Documented in the plugin README and sample config.

- **Partyline visibility for script timers** (mb527). `.scriptdryrun timers`
  lists armed timers (name, remaining/total delay, origin
  channel/nick/command, script) plus the runner's pending-slot cap;
  `.scriptdryrun canceltimers` cancels every armed timer and frees its
  pending slot. Cancellation never creates or executes anything.

- **Timer actions are now applied** (mb525). In `ACTION_MODE=apply`, a script
  returning `{ "type": "timer", "name": "...", "delay": N }` re-runs the same
  script after N seconds (1–3600) with the event `timer`; deferred
  reply/notice output passes through the same `ALLOW_IRC` and channel-scope
  guards as direct output. Guardrails: a timer-invoked run can never schedule
  further timers, duplicate pending names are rejected, at most 4 timers may
  be pending at once (runner cap, bounded at 20), and pending timers are
  cancelled when the plugin is unloaded or replaced.

### Fixed

- Script actions can no longer target a different channel than the one the
  command came from (mb524, cross-channel spam/harassment vector).
- Test-suite landmine: three release-contract tests installed dependency
  fallback stubs through named `sub` declarations, which are compiled
  unconditionally and silently overwrote the real
  `IO::Async::Timer::Countdown` methods for every later test in the shared
  harness process (mb525). Fallbacks are now runtime glob assignments.
- Script channel scoping now also recognizes IRC `STATUSMSG` targets such as
  `@#channel` and `%#channel`; these prefixes can no longer bypass the
  cross-channel guard (mb526).
- The mb525 timer test now creates its script fixture in a temporary directory
  instead of relying on `t/tmp_mb*_scripts`, which is intentionally protected
  as generated local state by the commit workflow (mb526).

---

## [3.3] — 2026-07-12

> Released after validation on the development instance and a complete fresh
> Debian 13 installation. Nothing below changes the database schema unless a
> migration is explicitly listed under "Migrations".

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
- Release packaging preserves the historical `mediabot_v3-X.Y` archive naming and the canonical `/home/wws/downloads/mediabot` publication path.

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
- Fresh database installation could fail while creating the application user:
  a malformed `sed` expression broke SQL literal escaping even for the generated
  alphanumeric password. SQL quoting is now dependency-free, checked explicitly,
  and verification rollback uses `DROP USER IF EXISTS` with validated literals.

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
- Tag-based public release builder creates deterministic `tar.gz` and `tar.xz`
  archives, includes the tracked `contrib/` and `plugins/` trees, excludes
  local/runtime-only material, and publishes SHA-256 and SHA-512 checksum files.

---

## [3.1] — stable (previous line)

Baseline stable release preceding the 3.2dev development line. See the git
history for the detailed 3.1 series changes.
