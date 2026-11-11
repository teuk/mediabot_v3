# Mediabot architecture roadmap

Accepted by the maintainer on 2026-11-11, after review of MB1207
(`d2efb58ddea9c370505b92639e2973233d2d02e0`).

This is the durable continuation plan. Read it before proposing the next
structural change and update its progress in the same patch as that change.
Use small reversible deliveries; do not bundle every phase into one migration.
Existing plugin architecture and API v2/v3 compatibility remain authoritative.

## Progress and sequence

| Phase | Objective and bounded first increment | Status |
| --- | --- | --- |
| A | Isolate Partyline `.plugins` administration behind explicit dependencies; keep historical entry points. | MB1208 accepted on host: 39,323 assertions; committed/pushed as `5fd3d59`. |
| B | Reduce Helpers' responsibilities and bidirectional dependencies. Map one output-policy path, give it a single owner, retain compatibility delegates. | MB1209 bounded increment accepted: 39,347 assertions; committed/pushed as `492a23b`. Further Helpers boundaries remain incremental. |
| C | Separate domain data access from commands and IRC transport. Pilot channel output rules, retaining cache freshness, last-known-good data and failure policy. | MB1210 R2 accepted: 39,386 assertions; committed/pushed as `97ced23`. |
| D | Make timer/worker/resource ownership and shutdown order explicit. Inventory existing resources first; migrate one family with idempotent cleanup. Distinguish shutdown, IRC reconnect and rehash. | MB1214 AntiFlood retirement committed/pushed as `b321e17`; three-family output pilot delivered. Detailed MB1214 host test report not supplied. |
| E | Reduce PluginManager responsibilities. Extract runtime-state persistence and diagnostics separately while keeping lifecycle/security authority explicit. | MB1215 persistence (`8467555`) and MB1216 portfolio diagnostics (`a9d10caa`) committed/pushed; bounded phase E pilot delivered. |
| Throughout | Replace source-body reconstruction with actual component tests and injected clock/transport/storage dependencies; retain native integration tests. | MB1208 (412, 1110), MB1209 (337, 627, 1538). |

## Phase A / MB1208

`Mediabot::Partyline::PluginAdmin` owns parsing, operator permission checks and
presentation for `.plugins`. It loads only core Perl dependencies and receives:

- the plugin manager, through its existing method interface;
- a writer exposing `write`;
- lazy providers for session level, optional autoload state and metrics.

`Partyline::Commands::_cmd_plugins` supplies those dependencies. Existing
Partyline methods and rendering helper aliases remain compatible. The manager
still owns plugin lifecycle, capabilities, storage namespaces and persistence.
This component is trusted operator code, not a sandbox or plugin capability API.

The command cases now invoke the real component without loading the entire bot.
Native Partyline lifecycle, config, storage and alias tests remain in the host
acceptance lane. The remaining large command body can later be separated into
parsing and rendering if concrete tests justify another increment.

Acceptance: exact wire responses, level gates, delegated operations, redaction,
compatibility aliases and command routing preserved; no additional repository
test file; full suite once before commit. Do not mark host acceptance complete
merely because the patch has been prepared or uploaded. Record the successful
host result/commit in the next delivery.

## Phase B / MB1209 — output admission

Before: Helpers owned the admission algorithm, SQL parameter cache, global
window and channel state; Sender and DeferredOutput reached it through the
historical helper. After: `IRC::OutputPolicy` owns that policy, with explicit
wall-clock, config and notification callbacks. Helpers remains the adapter;
Sender and DeferredOutput retain their established entry points and overrides.
The policy does not load Helpers or any transport. `IRC::OutputBudget` retains
monotonic refill ownership. Shared bot state and invalidation keys are unchanged.

Existing cases 337 and 1538 now call the real component rather than recompiling
its source; 627 tests its actual negative-cache behavior rather than a copied
algorithm. Native wiring remains in the host integration lane. The SQL cache
and its failure policy deliberately remain together until phase C; this bounded
increment does not complete all of phase B. No speedup is claimed.

Host acceptance of MB1209: 918 targeted and 39,347 full-suite assertions passed;
committed and pushed as `492a23b`. Boundary review: Helpers already delegates
command throttling, output transport and admission; cache invalidation still
shares `_af_params` with ChannelCommands. Keep that shared state intact while
piloting the adjacent read-only data-access boundary before broader extraction.

## Phase C / MB1210 — channel flood rules reader

`Channel::FloodRules::read` receives only a DBI-compatible handle and channel ID.
It owns the parameter SELECT and returns distinct found/missing/error results;
DBI exceptions propagate unchanged. It has no bot, transport, clock or cache.
`IRC::OutputPolicy` retains defaults, positive/negative cache freshness, channel
lookup, diagnostics and admission fallback. ChannelCommands keeps writes and
existing cache invalidation. No second cache is introduced.

This pilot preserves the existing anti-flood failure policy: false prepare or
execute logs and falls back to global admission without refreshing the cache.
Previously confirmed entries and their age remain stored, but stale entries are
not enforced on that failed read. Missing rows create the existing negative
cache. This differs from the badword filter's last-known-good enforcement;
those policies must not be merged. Statement cleanup and thrown errors are
unchanged, including no explicit finish on false execute. Further cleanup work
must be a separately tested behavior change.

MB1210 R2 host acceptance: 956 targeted and 39,386 full-suite assertions passed;
committed/pushed as `97ced23`. The DBI fault fixture now isolates its scalar slot
without writing to DBI's special variable; native diagnostic restoration passed.

## Phase D / MB1211 — inventory before migration

See [Runtime resource ownership](RUNTIME_RESOURCE_OWNERSHIP.md) for the bounded
source inventory, reconnect/rehash/final-exit distinctions and observed gaps.
The first runtime migration selected is explicit retirement of paced NOTICE
callbacks and notifiers on transport replacement. Existing registry identity
already prevents stale sends; physical removal and payload revocation need an
explicit contract, including inline expiry, reentrancy and cleanup failures.

MB1211 documentation checkpoint was accepted and pushed as `a29a67f` after
reference/patch checks; no runtime suite was required for that docs-only change.

### MB1212 — explicit NOTICE retirement

`IRC::Timer::cancel_countdown` revokes the callback and its captured payload before
attempting stop/remove independently. Weak-key registrations do not own notifier
lifetimes. A cleanup exception returns 0; repeated calls are inert and do not
retry failed physical removal. The existing countdown return value is preserved.
`PacedOutput::retire_notice_timers` empties only the detached registry and reports
incomplete cleanup. `setIrc` publishes the new transport before retirement, so
nested replacement/sends cannot be overwritten or cancelled by the old cleanup.
Late timers returned after a transport change during add/start are retired too.

Same-transport assignments and rehash retain their behavior. PRIVMSG and flood
queues keep existing identity invalidation; no global shutdown coordinator or
child-process migration is introduced. Existing tests cover cancellation faults,
retained callbacks, native notifier removal, inline expiry and reentrant wiring.
MB1212 host acceptance: 798 targeted and 39,423 full-suite assertions passed;
committed/pushed as `62f83c0`.

### MB1213 — explicit paced PRIVMSG retirement

`PacedOutput::retire_privmsg_queues` revokes all detached target states before
notifier cleanup: current and waiting batches, send guards, pump/schedule closures
and notifier slots. `setIrc` publishes the new transport before calling it.
Dormant queues retained after a failed arm are also released on replacement.
Same-transport assignments and ordinary setup-failure recovery remain intact.

Each arm has an identity token so an inline expiry cannot overwrite a successor
notifier with its late return value. Late timers from a retired connection are
cancelled. Stop/remove faults retain callback revocation and emit a diagnostic;
cleanup reentry cannot retire new work. Existing isolated and native paced tests
cover these contracts. MB1213 host acceptance: 837 targeted and 39,462 full-suite
assertions passed; committed/pushed as `52e250e`.

### MB1214 — explicit AntiFlood drain ownership and retirement

`DeferredOutput` now owns a countdown handle and an arm identity per target queue.
Expiry releases these slots before the legacy drain hook. Inline expiry and late
setup failure cannot overwrite or clear a successor arm. An explicit drain also
retires any still-pending arm before processing its item.

`retire_flood_queues` clears every detached queue's payload and arm slots before
cancelling countdowns. `setIrc` publishes the replacement transport first;
cleanup reentry preserves new queues. Dormant failed-arm/no-loop queues are
cleared too. Cleanup failure is reported without restoring permission to send.
Existing line costs, FIFO/retry order, response expiry, queue cap, target spelling
and dynamic Helpers hooks remain unchanged. No global shutdown migration.

MB1214 is present on GitHub as `b321e17` and matches the supplied snapshot.
Its detailed host test report was not supplied; no assertion total is inferred.
The three-family output pilot is delivered. Remaining worker/final-shutdown
questions in phase D stay explicitly deferred.

## Phase E / MB1215 — runtime-state file persistence

`Plugin::RuntimeStateFile` owns JSON encoding/decoding, bounded file reads,
private exclusive temporary-file creation, cleanup and rename publication.
It loads core dependencies only and receives the size bound, a lazy path resolver
and a read validator. It does not receive a bot or manager and has no lifecycle,
capability, scheduler or plugin-loading authority.

PluginManager retains snapshot construction, schema/grant/policy validation,
trusted directory selection, restore order and rollback after persistence errors.
Its existing methods/globals remain compatible adapters. Encoding and size
checks still precede directory creation; return tuples, messages, file mode,
symlink handling and historical JSON decoding are preserved. This extraction
does not claim to add fsync durability or change file-system race policies.

Existing 1135 exercises the real component and existing manager round trips;
1136 retains restore/failure isolation; 1137 follows the new file owner for its
publication contract. MB1215 is present on GitHub as `8467555` and matches the
supplied snapshot. Its detailed host test report was not supplied; no assertion
total is inferred.

### MB1216 — portfolio diagnostics assembly

Individual diagnostics already belong to `Plugin::DiagnosticsV3`. The portfolio
aggregation now joins them there: sorted installed/live union, collision and
unloaded rows, detached policy counts, full summary and 64-row output cap.
The component receives four read callbacks (discover, list, entry, report),
preserving observation order and exception propagation. It loads no manager,
bot, filesystem discovery or lifecycle machinery itself.

PluginManager retains discovery and live-entry/report access; its public
`v3_portfolio_report` remains the adapter. No quarantine, permission enforcement,
plugin mutation or rollback responsibility moves. Existing 1129 tests exercise
both actual manager wiring and standalone assembly; no new repository case.
MB1216 local targeted lane: 246 assertions passed. Commit `a9d10caa` is now on
GitHub and matches the snapshot. Detailed host test results were not supplied;
no full-suite assertion count is inferred.

## MB1217 — integration checkpoint and next bounded priority

Reviewed at `a9d10caaccaaceaa4a4ab788fa524c303707bae3` against the supplied
2026-11-11 snapshot. This is a documentation-only checkpoint, not a new runtime
migration or a claim that every completion criterion is satisfied.

| Boundary | Current ownership and integration evidence | Remaining scope |
| --- | --- | --- |
| A: operator administration | [Commands](../Mediabot/Partyline/Commands.pm) `_cmd_plugins` delegates to [PluginAdmin](../Mediabot/Partyline/PluginAdmin.pm); existing [412](../t/cases/412_mb173_partyline_plugins_status.t) exercises the component. | Other Partyline command families remain separate candidates; retain session/level authority. |
| B/C: output admission and storage | [OutputPolicy](../Mediabot/IRC/OutputPolicy.pm) owns cache/budget decisions; [FloodRules](../Mediabot/Channel/FloodRules.pm) owns the SELECT. [627](../t/cases/627_mb409_antiflood_negative_cache.t) covers failure/cache boundaries. | ChannelCommands still writes rules and invalidates shared cache. Do not merge domain-specific fallback policies. |
| D: connection output | [setIrc](../Mediabot/Mediabot.pm) detaches registries and publishes the transport before [paced](../Mediabot/IRC/PacedOutput.pm) and [deferred](../Mediabot/IRC/DeferredOutput.pm) retirement. [1311](../t/cases/1311_mb882_irc_native_timer_lifecycle.t) retains native coverage. | MB1218 adds separate periodic nicklist retirement; worker/final-exit coordination remains open. |
| E: state file | [RuntimeStateFile](../Mediabot/Plugin/RuntimeStateFile.pm) owns file IO; [PluginManager](../Mediabot/PluginManager.pm) retains validation, path policy and rollback. [1135](../t/cases/1135_mb766_v3_boot_state.t) exercises real manager restoration and standalone IO. | No fsync durability or new filesystem race policy was introduced. |
| E: diagnostics | [DiagnosticsV3](../Mediabot/Plugin/DiagnosticsV3.pm) owns detached reports/portfolio assembly; [1129](../t/cases/1129_mb764_v3_portfolio_report.t) covers actual manager wiring and bounded standalone assembly. | Discovery, quarantine and capability/lifecycle decisions remain with the manager. |

### Next runtime increment: nicklist timer retirement

Inspection of `stop_all_channel_nicklist_timers` and
`stop_channel_nicklist_timer` in Mediabot.pm shows two concrete failure paths:

- Loop removal and timer stop share an eval. If removal throws, stop is skipped.
  The all-channel path nevertheless clears the registry and logs success.
- Registry deletion happens after external cleanup. A replacement registered by
  reentrant cleanup can therefore be erased, either for one channel or globally.

`setup_channel_nicklist_timers` also installs periodic callbacks without an
explicit registration identity gate. Treat callback revocation as a distinct
requirement from physical stop/remove. These are source-level findings; this
checkpoint does not claim a production incident or a passing fault reproduction.

The nicklist portion of [388](../t/cases/388_mb129_nicklist_timer_and_metrics_utf8.t)
currently models setup/stop with local closures rather than invoking these
methods. Preserve its unrelated UTF-8 metrics assertions, but replace the
lifecycle simulation with real-owner tests in the runtime increment.

Acceptance requirements for that increment:

1. Detach only the old owned registration before cleanup; reentrant successor
   timers for the same or another channel survive.
2. Attempt stop and removal independently; report incomplete cleanup honestly.
3. Retained callbacks from retired registrations cannot refresh the nicklist.
4. Preserve the configured interval, default 300 seconds, target spelling and
   add/part/join/purge/reconnect/rehash behavior. Audit the calls in
   [ChannelCommands](../Mediabot/ChannelCommands.pm) before changing the boundary.
5. Cover normal completion, stop/remove faults, repeated cleanup, reentrant
   replacement and setup failure against real owner methods; retain a native
   periodic-timer integration check and run the full suite once before commit.

Do not route periodic timers through the countdown-only cancellation API.
[DBCommands](../Mediabot/DBCommands.pm) `_stop_all_runtime_db_timers` already
separates its cleanup attempts, and [ShellWatch](../Mediabot/Partyline/ShellWatch.pm)
`_dispose` demonstrates identity-aware retirement; neither is a drop-in nicklist
implementation. Choose the smallest owner boundary that the new tests justify.

Worker shutdown, Scheduler policy, database writes, radio and YouTube remain
outside this next increment. A universal resource container or stop-all service
is not a prerequisite. No startup/runtime performance gain is claimed.

Checkpoint validation: verify documentation paths/source symbols, exact base,
patch/reverse and guarded commit flow. No runtime code changes, so the full
runtime suite is not rerun for MB1217 alone.

## MB1218 — periodic nicklist retirement

Base: `a0fcaf84ca506e14344b464b363a4587a0e3f91c` (MB1217 committed).
[Channel::NicklistTimers](../Mediabot/Channel/NicklistTimers.pm) now owns periodic
setup, registration identity and retirement. Mediabot keeps the three historical
methods as delegates and still owns NAMES delivery, configuration, channels and
loop. Public registry values remain timers; private weak-key metadata stores
revocable callback state and the original loop. Loading the owner needs only
core Perl; the default periodic factory loads IO::Async lazily.

Both old failure modes were reproduced locally from the base stop methods:
remove exceptions skipped stop, and single/all cleanup erased reentrant
successors. Retirement now detaches old registrations and revokes every old
callback before cleanup. Remove and stop are attempted independently; incomplete
cleanup returns 0 and is logged instead of claiming success. Existing callers
ignore that result. Repeated retirement does not retry failed physical cleanup.
A setup generation and per-timer identity protect nested setup and late add/start
returns. Setup failures clean only the old registration and rethrow the original
exception. Retained callbacks hold weak bot/loop references and become inert.

Configured/default intervals (300 seconds), channel spelling and the existing
add/part/join/purge/reconnect/rehash call sites are unchanged. Periodic timers do
not use the countdown cancellation API. Existing case 388 now tests the actual
component with an injected factory; UTF-8 assertions remain. Case 1311 adds actual
Mediabot facade/native periodic integration; 1304 checks independent loading.
MB1218 is committed on GitHub as `7f1529b3` and matches the supplied snapshot.
Detailed host test results were not supplied; no full-suite count is inferred.

Next: review worker/final-exit ownership and select one bounded consumer before
changing shutdown behavior. Async cancellation, child reaping and synchronous
final exit must remain distinct; no universal stop-all coordinator is assumed.

## MB1219 — achievement worker result retirement

Base: `7f1529b34ec271852c6de4bd87206e517fa082ea`, matched to the supplied
2026-11-11 11:17:32 snapshot. Review of `clean_and_exit`, archive termination,
`Achievements::shutdown_worker`, its process watcher and parent completion path
selects one bounded ownership defect before broader process migration.

Shutdown already refused new checks and sent TERM, but left the parent's active
token valid. Actual-component tests reproduced late success unlocking achievements
and importing progress; late failure changed retry state and outcome metrics.
`shutdown_worker` now revokes logical ownership before signalling and publishes
an idle gauge once. `_finish_async_check` refuses results after shutdown begins.
Queued checks remain unacknowledged and existing achievements/final save survive.
No cancelled completion is counted as a success, timeout or failure.

This gate concerns callbacks arriving after shutdown; it does not interrupt a
completion already executing. Child TERM, stream/timer cleanup, watch_process and
reaping stay unchanged. The gauge means logical parent work, not OS child count.
No waits, blocking join, AsyncWorker conversion or reconnect policy are added.
Existing case 751 covers late success/failure, duplicate delivery, repeated/idle
shutdown, refusal of new work and final save. Eight local cases / 162 assertions
passed. Wider integration needs host dependencies; targeted and full host suite
remain mandatory before commit. No new repository test file.

Next bounded review: achievement child physical termination and reaping at final
exit, including watcher/setup failures and the difference between TERM request
and confirmed exit. Preserve archive termination ordering and avoid copying its
blocking wait into ordinary async cancellation or reconnect.

## Rules for subsequent phases

1. Record the base revision and compare supplied source snapshots explicitly.
2. Describe ownership and dependencies before and after each change; fewer lines
   in a file alone are not evidence of architectural improvement.
3. Preserve commands, permissions, wire output and default behavior. Any intended
   behavior change needs its own explanation and tests.
4. Keep SQL failure policies domain-specific: authorization, optional archives,
   output rules and writes must not share an indiscriminate fallback policy.
5. Keep security checks at an identified authority; avoid a second inconsistent
   copy in a generic service container.
6. Use explicit dependencies at the extracted boundary, preserving lazy access
   when timing matters. Retain compatibility facades until callers are migrated.
7. No database schema, production configuration or service changes in this plan
   unless separately requested. Radio and YouTube behavior remain sensitive.
8. Validate focused contracts and native wiring, then the full suite once with
   visible progress on the host. Commit/push with the existing commit.sh flow.
9. Record measured test/startup effects when available; do not promise a speedup
   from extraction alone. Never delete coverage only to reduce the test count.

## Completion criteria

- Components can be loaded/tested without unrelated runtime dependencies.
- Each cache, worker and timer has an identifiable owner and lifecycle policy.
- Domain SQL operations live behind named interfaces with explicit error rules.
- The runtime coordinates services; transport and commands do not accumulate
  unrelated business rules.
- Integration tests cover compatibility facades and native runtime wiring.
