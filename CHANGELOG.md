# Changelog — Mediabot v3

All notable changes to Mediabot v3 are documented here.

Versioning follows the project rule: odd minor versions are stable releases
and even minor versions are development lines. **3.3** is the current stable
release. Development after this release continues on the `3.4dev` line.

---

## [Unreleased] — 3.4dev

### Fixed — regression guards caught up with mb559 (mb560)

- Two static guards were stricter than the contracts they encode and failed
  on the legitimate mb559 async worker. The DSN guard now checks "every
  DBI->connect site is timeout-bounded" instead of hard-coding two sites
  (the worker's isolated connection is bounded too, and now counted); the
  duplicate-sub guard now scopes detection by package, accepting the
  Mediabot::Achievements::Worker post-fork overrides while still failing on
  a real duplicate inside one package. Test-only round: no runtime change.

### Fixed — truthful achievement worker outcomes (mb560)

- Successful asynchronous achievement workers now retain the bounded
  `result="ok"` label. The original mb559 whitelist accidentally rewrote that
  valid value to `failed`, which made Grafana's 24-hour worker-failure panel
  count healthy completions. Regression coverage now locks both successful
  and timeout outcome labels.

### Fixed — isolated asynchronous achievement workers (mb559)

- Achievement CHANNEL_LOG aggregations now run in a forked child with a fresh,
  child-only MariaDB connection. The parent event loop only starts one worker,
  reads a bounded JSON result through IO::Async, and applies unlocks after a
  validated success. A 75-second hard timeout, TERM/KILL escalation, bounded
  retries and shutdown cleanup prevent stuck or orphaned work. The inherited
  parent DBI socket is marked InactiveDestroy in the child and is never reused.
- Queue entries remain pending until success; failures rotate with backoff and
  are dropped only after three attempts. Prometheus exposes pending/in-flight
  gauges, worker results, timeouts and bounded-drop reasons. The scheduler runs
  the non-blocking launcher every second, so it can drain promptly without ever
  executing achievement SQL itself.

### Fixed — achievements checks off the PRIVMSG path (mb558)

- Root cause of the 48s "calc" incident (Undernet, 2026-07-23, caught by
  the mb548/550 tracers): the three CHANNEL_LOG aggregations behind the
  message-count, hour-band and polyphony achievements ran synchronously
  inside the PRIVMSG path — the first unthrottled passage on a large
  history table cost tens of seconds. The hot path now only enqueues
  (queue_check: case-insensitive dedup, original casing preserved, bounded
  at 200). MB559 completes this queue foundation with an isolated async
  worker; the Scheduler only launches work and never executes the historical
  scans in the event-loop process. Unlock semantics, thresholds and existing
  throttles remain unchanged, while delivery delay is now observable through
  queue and worker metrics rather than promised to be only a few seconds.
- Each aggregation is now individually timed: slow ones log
  "SLOW ACHIEVEMENT: <check> for <nick>/<chan> took X.XXs" (level 3) and
  every duration feeds mediabot_achievement_check_seconds{check} (fixed
  cardinality); p95-by-check panel added to the overview dashboard.

### Fixed — scheduler metrics startup wiring (mb557)

- The scheduler is now attached to Metrics only after the Scheduler object is
  constructed. The earlier pre-construction call was a silent no-op, so slow
  scheduler logs worked but the new histogram remained empty at runtime.
  The regression contract now verifies ordering, rejects the dead early call,
  and exercises Scheduler::set_metrics directly.

### Added — scheduler tick timing (mb556)

- The named scheduler tasks get the same timing discipline as PRIVMSG, the
  event loop and the partyline — the tracing quadriptych is complete. Both
  execution modes (periodic and calendar) run their callback through one
  shared timed helper: every duration feeds the new
  mediabot_scheduler_tick_seconds{task} histogram (bounded cardinality:
  internal task registry only), any task above one second logs
  "SLOW SCHEDULER: task 'name' took X.XXs" at level 3, and error semantics
  are preserved (a dying callback still logs at level 1, its duration still
  observed). Best-effort metrics via Scheduler::set_metrics (mb550
  pattern); a p95-by-task panel joins the overview dashboard.

### Fixed — kick action scope and wire safety (mb555)

- Kick actions now canonicalize STATUSMSG-decorated channel contexts, reject
  malformed channel targets, enforce the IRC first-character nickname rule,
  bound reasons to 120 UTF-8 bytes, and encode Unicode reasons before the IRC
  write path. Self-kick protection is fail-closed when bot identity cannot be
  checked, and gatekeeper logs a truthful kick request rather than claiming
  that a rejected or failed kick already happened.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Kick action** (mb554). Scripts may emit
  {"type": "kick", "nick": "...", "reason": "..."} to eject a nick from
  their ORIGINATING channel. Same fail-closed shape as the topic action:
  no target field accepted, channel context required, nick validated
  against the IRC charset (max 30), reason bounded to 120 with an explicit
  default, and three gates to apply — ACTION_MODE=apply, ALLOW_IRC=yes and
  the dedicated ALLOW_KICK=yes (default no, hot-reloadable, distinct
  refusal errors). The bridge refuses to kick the bot itself and fails
  closed if its current IRC identity cannot be verified at apply time.
- **gatekeeper.pl**, the canonical join-time use: case-insensitive
  substring matching on the joining nick (no user-supplied regex by
  design), total silence on normal joins, an unarmed configuration that
  never kicks. Fifteen examples now ship; cookbook count and citations
  updated under the mb538 guards.

### Fixed — observability truth and non-blocking status (mb553)

- Histogram observations and bucket bounds now accept finite scientific
  notation produced legitimately by Time::HiRes, so very fast runs are no
  longer dropped silently. `.status` reads the DB handle state maintained by
  the canonical five-second health tick instead of performing a synchronous
  ping/reconnect from the partyline. `data.network` is enforced as a reserved
  read-only field, absent without current LUSERS data, and failed LUSERS sends
  no longer advance the refresh throttle or prolong stale snapshots.

### Added — network envelope, status health, partyline tracer (mb552)

- **data.network in the script envelope**: a read-only snapshot (users,
  users_max, channels, servers, operators, age_seconds) built FRESH at
  every payload construction — including deferred timer runs, which see the
  network as it is NOW while their data.config stays the arming-time
  snapshot. Whitelisted fields only, per-field garbage rejection, absent
  entirely until LUSERS data exists; fractional epochs accepted.
- **.status infrastructure lines**: cached DB up/DOWN from the canonical
  five-second health tick (no synchronous partyline probe) and the last
  event-loop stall (or "no stall detected").
- **SLOW PARTYLINE tracer**: the partyline line dispatcher gets the same
  end-to-end timing discipline as the PRIVMSG wrapper — any command above
  one second logs its name and duration at level 3.

### Added — latency histograms (mb551)

- **Histogram metric type** in Mediabot::Metrics: declare(..., 'histogram',
  help, buckets => [...]) with sorted/deduplicated/validated bounds
  (latency defaults when omitted), observe(name, value, labels), and full
  Prometheus exposition (cumulative _bucket lines with le="+Inf", _sum,
  _count, per label set). Backward compatible with the legacy positional
  label-list argument.
- **Two latencies become distributions**: mediabot_privmsg_processing_seconds
  (fed by the PRIVMSG wrapper on every message — the SLOW threshold log is
  unchanged) and mediabot_scriptbridge_run_seconds{origin} (fed from the
  run duration now measured with sub-second precision by ScriptRunner and
  exposed as result->{duration_s}).
- **Dashboards**: p50/p95 PRIVMSG panel on the overview, p95-by-origin panel
  on the scriptbridge dashboard; the dashboard truth contracts learned to
  resolve histogram _bucket/_sum/_count suffixes (trying the full name
  first, since real series can legitimately end in _count).

### Added — DB health metrics and event-loop stall detector (mb550)

- **DB health as Prometheus series**: mediabot_db_up (gauge),
  mediabot_db_reconnects_total{result}, mediabot_db_slow_pings_total —
  emitted from the already-timed ensure_connected path (best-effort
  injection via DB::set_metrics; behavior unchanged without Metrics, and
  a failed reconnect reports db_up=0, consistent with the mb549
  stale-handle fix).
- **Event-loop stall detector**: the 5s periodic tick measures its own
  lateness; any drift beyond 2s logs "event loop stalled ~X.Xs" at level 1,
  increments mediabot_loop_stalls_total and keeps the last stall for
  operator views. Catches synchronous freezes (SQL, DNS, disk) that never
  touch the PRIVMSG path.
- **Overview dashboard**: new Infrastructure row (DB up, reconnects, slow
  pings, loop stalls — compact stats plus two rate panels).

### Fixed/Added — first-command lag diagnosis and hardening (mb548, corrected by mb549)

- **Bounded DB network waits**: both DSN construction sites now set
  mariadb_connect_timeout/read_timeout/write_timeout (mysql.CONNECT_TIMEOUT/
  READ_TIMEOUT/WRITE_TIMEOUT, defaults 5/30/30, bounded). A silently dropped
  idle connection can no longer stall the first command indefinitely.
- **Timed reconnect path**: ensure_connected logs slow pings (level 3, with
  duration) and every reconnect's duration and accurate outcome (level 1),
  clears a dead stale handle before retrying, and never reports success or
  returns the old handle when reconnect fails.
- **Single periodic DB health check**: the existing A4 check on the five-second
  tick remains the canonical keepalive and legacy-dbh synchronization point;
  the diagnostic round does not add a redundant second ping.
- **SLOW PRIVMSG tracer**: end-to-end timing wrapper around the PRIVMSG
  handler; any processing above one second logs its duration and origin at
  level 3 while preserving the caller's scalar/list/void context.

### Fixed — topic action wire safety (mb547)

- Topic actions now canonicalize a STATUSMSG-decorated context to the
  underlying channel, reject malformed context targets before sending, and
  encode Unicode topic text to UTF-8 bytes just like reply/notice actions.
  This prevents invalid TOPIC destinations and wide-character failures in the
  IO::Async write path.

### Changed — plugin bridge examples (mb546)

- **topicreminder.pl learns mode=restore**. With
  `CONFIG_topic=remind_after=900;mode=restore`, the deferred run RE-SETS the
  original topic through the mb545 topic action instead of re-posting it as
  a reply — the canonical demonstration that per-route config can select
  between action types, and that the topic action's triple gate applies to
  deferred runs exactly as to immediate ones (a closed gate leaves the
  dedicated apply error visible in `.scriptdryrun last`, and nothing is
  sent). Default behavior (mode absent or invalid) is unchanged: remind.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Topic action** (mb545). Scripts may emit
  `{"type": "topic", "text": "..."}` to change the topic of their
  ORIGINATING channel. Deliberately fail-closed: no `target` field is
  accepted (the channel always comes from the run context, so no
  cross-channel variant exists by construction), a channel context is
  required, the text is capped at 300 characters, and applying it needs
  three gates — `ACTION_MODE=apply`, `ALLOW_IRC=yes` and the dedicated
  `ALLOW_TOPIC=yes` (default no, hot-reloadable, each refusal carrying its
  own distinct error). Dry-run plans the action like any other; the gate is
  visible in `.scriptdryrun status`/`last` and documented in the partyline
  config reference, sample conf, README and cookbook.

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
