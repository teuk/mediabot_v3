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
| B | Reduce Helpers' responsibilities and bidirectional dependencies. Map one output-policy path, give it a single owner, retain compatibility delegates. | MB1209 bounded increment accepted: 39,347 assertions; committed/pushed as `492a23b`. MB1241 local VERSION policy is committed (`55eedd9e`). MB1242 command presentation is committed (`2db3d45b`); detailed host acceptance totals not supplied. MB1243 checkpoints this bounded split. |
| C | Separate domain data access from commands and IRC transport. Pilot channel output rules, retaining cache freshness, last-known-good data and failure policy. | MB1210 R2 reader accepted (`97ced23`); operator UPDATE committed in MB1232 (`cdbdbee6`). MB1233 display read committed (`7b478567`). Antifloodset and badword read/write pilots (MB1235–1236) are committed. MB1244 antiflood read is committed (`dd2a8605`). MB1245 registration is committed (`15680ec`). MB1246 flags reader is committed (`7326eb8`). MB1247 checkpoints the bounded chaninfo split; detailed host totals were not supplied. Broader phase C remains open. |
| D | Make timer/worker/resource ownership and shutdown order explicit. Inventory existing resources first; migrate one family with idempotent cleanup. Distinguish shutdown, IRC reconnect and rehash. | Connection output and nicklist retirement delivered (MB1212–1214, MB1218); achievement ownership/collection (MB1219–1225) and archive collection (MB1226, `473a0b1b`) committed. Plugin-job recovery/identity delivered (MB1228–1230). Phase D remains open; MB1238 publication fix committed (`35bdd3b4`); MB1239 tick revalidation committed (`8437a890`); detailed host acceptance transcripts not supplied. |
| E | Reduce PluginManager responsibilities. Extract runtime-state persistence and diagnostics separately while keeping lifecycle/security authority explicit. | MB1215 persistence (`8467555`) and MB1216 portfolio diagnostics (`a9d10caa`) committed/pushed; bounded phase E pilot delivered. |
| Throughout | Replace source-body reconstruction with actual component tests and injected clock/transport/storage dependencies; retain native integration tests. | MB1208 (412, 1110), MB1209 (337, 627, 1538), MB1232–1233 native antifloodset case 398. |

Current continuation point: MB1250 extracts the user candidate cursor opener.
See [MB1250](#mb1250--user-candidate-cursor-owner).
Earlier “Next” paragraphs are historical decisions.

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

## MB1220 — watcher rejection owns its child cleanup

MB1219 is committed as `c787a6b0` and matches the supplied 11:39:03 snapshot;
its detailed target-host test report was not supplied. Physical-lifecycle review
identified a smaller prerequisite than final-exit migration: when achievement
watch_process registration throws, the parent killed its child but never waited
for it. An isolated real fork probe reproduced an uncollected child on the base.

That exceptional setup path now marks callback state finalized, breaks its finish
closure, sends the existing KILL, closes its pipe and polls only that PID with
WNOHANG (20 attempts, 5 ms between attempts). A matching PID or ECHILD confirms
collection; EINTR consumes the same bounded budget. Other failures or exhaustion
log an unconfirmed reap. No unbounded wait or successful-cleanup guarantee is
introduced; a pathological uncollectable child remains an explicit limitation.
The original worker_setup/watch_process result and one completion are retained.
Normal watcher-owned completion, timeout escalation and TERM-only final shutdown
are unchanged. AsyncWorker already uses a similar bounded setup-failure reap;
this increment does not create a universal process cancellation service.

Existing case 751 invokes a fresh-interpreter real-child probe so SIGCHLD and
IO::Async doubles cannot contaminate the shared harness. The fixture cleans its
child even against the failing baseline. Local eight-case lane: 167 assertions
passed, including 48 in 751. Full host acceptance remains required before commit.

Next: review successful watcher installation followed by stream/timer setup
failure, then the final-exit TERM/reap contract. Preserve result revocation from
MB1219 and distinguish logical completion from confirmed child exit.

## MB1221 — partial worker installation cleanup

MB1220 is committed as `f98fcf24` and matches the 12:05:51 supplied snapshot;
no detailed host test total is inferred. Native fault injection reproduced leaks
when stream/countdown construction, partial loop add or timer start throws after
watch_process succeeds. The outer launcher caught the exception but did not own
notifier cleanup; the registered child watcher alone was insufficient.

The installation boundary now catches those failures, finalizes state and revokes
the finish callback before KILL (unless child completion was already observed),
stops/removes its timers, closes/removes its stream and closes its pipe. Cleanup
attempts are best effort; exceptions in one do not suppress the other attempts.
No synchronous wait is added: the accepted watcher still owns reaping. Exactly
one worker_setup/notifier_setup result is delivered unless inline completion has
already delivered the result. Retained read/expiry callbacks are inert, and late
child completion cannot erase newer work. A completed process is not republished.

Existing 751 and its fresh-interpreter probe now cover five native setup faults,
normal completion and completion during add with/without a subsequent exception.
The worker case has 87 assertions; the final eight-case local lane passed 206
assertions. Full host integration remains mandatory before commit. No new case.

Next: final-exit physical termination/reaping remains separate from this launch
repair. Timeout escalation setup and cleanup failures deserve their own contract;
do not merge watcher-owned completion with synchronous shutdown waits.

## MB1222 — timeout escalation installation boundary

MB1221 is committed as `04e84565`; changed inputs match the supplied 12:21:38
snapshot. Six native fault injections reproduce exceptions escaping the timeout
callback when escalation countdown construction, attachment or start fails.

The timeout callback now owns this installation boundary. On failure it sends
KILL unless child completion has already been observed and invokes the existing
forced completion path. That path retires partial timers and transport resources,
delivers one worker_timeout result and revokes subsequent completion. The accepted
process watcher still owns reaping. No synchronous wait or new cancellation
service is introduced; normal TERM/KILL delays remain unchanged.

The existing 751 probe covers all six failures, immediate single completion,
watcher reaping, notifier cleanup and successor preservation after stale callbacks.
Local eight-case lane: 230 assertions passed (111 in 751). Full host validation
remains required; no host total is inferred from the snapshot.

Next: audit final-exit physical termination and reaping separately. Best-effort
notifier removal still cannot guarantee success if the loop refuses cleanup.

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

### MB1222 R2 host acceptance repair

R1 passed 316 targeted assertions on the host; full validation failed at AI
assertions 662 and 666. Native diagnostics confirmed two eight-second worker
timeouts with zero output, not a size-policy failure. The six-child size fixture
now uses a 30-second request budget (33-second worker budget), a 40-second overall
wait and raw worker diagnostics. All payloads and assertions remain unchanged.
Production timeouts and timeout-specific tests are untouched. Full host
acceptance must be rerun before committing MB1222.

## MB1223 — separate process ownership from result delivery

MB1222 R2 is committed as `0d8d00d9`; changed inputs match the supplied 13:21:30
snapshot. The final-exit audit reproduced a stale PID ownership interval: the
native watcher had reaped the child, but the pipe had not delivered EOF. The old
process record remained available to shutdown_worker, which could signal a PID
no longer owned by the bot. This is a reproduced state defect, not evidence that
an unrelated process has actually been signalled in production.

The accepted watcher now retires the exact process record on observed exit.
Result delivery still waits for EOF as before. Final cleanup only removes its
own record, and inline child exit cannot be followed by republishing a dead PID.
The existing probe covers both ordinary and inline child exit before EOF, native
reaping, single eventual completion, timer cleanup and successor preservation.
Local eight-case lane: 238 assertions passed, including 119 in case 751. Full
host acceptance is still required; no host test total is inferred from a commit.

Next: determine the final-exit policy for children still alive when the loop is
stopped. This increment does not make TERM a confirmed termination or add waits.

## MB1224 — bounded physical shutdown of the active achievement child

MB1223 is committed as `3e45ff6f`; changed inputs match the supplied 13:35:31
snapshot. Native tests reproduced an unreaped child and attached worker notifiers
after shutdown without event-loop iterations, including a child ignoring TERM.

shutdown_worker now revokes the active process callbacks and detaches its timers,
stream and pipe before attempting termination. WNOHANG verifies child ownership
before either TERM or KILL. Each signal phase allows twenty five-millisecond
polls; there is no blocking waitpid or loop iteration. ECHILD counts as already
collected, EINTR uses the same bounded polling budget, and other errors stop the
attempt. The watcher is unregistered after confirmed collection. Otherwise a
bounded diagnostic records unconfirmed collection and the method returns false.
Actual scheduling can extend elapsed wall time beyond the nominal polling budget.

Normal worker execution retains watcher-owned asynchronous reaping. Final shutdown
of the currently registered process is the explicit ownership transfer to the
synchronous exit path. Logical revocation and final-save ordering are unchanged.
Repeated shutdown is inert; stale read, watcher and timer callbacks cannot deliver.
Existing case 751 includes native responsive/resistant children with a readiness
handshake and no loop iterations. Local eight-case lane: 246 assertions passed,
including 127 in 751. Full host acceptance remains required before commit.

Scope limit: this covers the active process record, not a universal worker drain.
A process whose forced completion already removed that record still belongs to
its watcher; a process-wide shutdown registry remains a separate design question.
Next: review that detached-but-not-yet-reaped case and archive worker shutdown,
then checkpoint phase D against the remaining roadmap rather than declaring
all runtime resources drained.

## MB1225 — physical child ownership outlives forced result completion

MB1224 is committed as `edf78e08`; changed inputs match the supplied 13:55:05
snapshot. Native readiness-controlled tests reproduce an ignored-TERM child
surviving final shutdown after forced result completion, both alone and alongside
an active successor. The old active-only shutdown collects only the successor.

Accepted watchers now register child records separately from _worker_process.
The active result slot retains its existing behavior; physical records survive
forced delivery or notifier setup failure until the watcher confirms exit.
Watcher removal is scoped to the exact record and removes the empty registry.
Final shutdown includes all retained children plus an older active-only record
for compatibility. It cleans active callbacks, checks ownership before signalling,
and polls the entire batch with one shared twenty-by-5ms budget per TERM/KILL
phase. There is no event-loop iteration or blocking waitpid. Polling work scales
with child count; scheduling can extend wall time beyond the nominal sleep budget.

Confirmed records are removed and unwatched. Unconfirmed records remain available
for watcher completion or a subsequent shutdown attempt; false return and the
existing diagnostic remain explicit. Registry entries do not claim children have
exited merely because their results completed. Native stale callbacks cannot
repeat delivery. Setup/normal completion coverage also checks registry removal.

Local eight-case lane passed 254 assertions; final worker-case verification passed
135 assertions. Full host validation remains mandatory; no host total is inferred
from the supplied commit. This is achievement-scoped ownership, not a universal
process supervisor. Rejected watcher registration retains its existing bounded
local collection path and diagnostic if collection is not confirmed.

Next: audit archive-worker final shutdown, which still contains a blocking wait,
and checkpoint phase D against the other resource owners before broader changes.

## MB1226 — bounded archive worker collection

MB1225 is committed as `b657c1e4`; changed inputs match the supplied 14:09:05
snapshot. A deterministic baseline probe reaches blocking waitpid after TERM/KILL.
Both final exit and rejected watcher registration previously used an unbounded
wait; final exit also treated every waitpid error as successful collection.

One archive-specific routine now owns both paths. Final exit uses TERM then KILL;
watcher registration failure keeps immediate KILL. Each phase permits ten 50ms
polls, followed by a nonblocking final check. ECHILD means already collected;
EINTR consumes the same budget, and other wait errors stop without signalling.
Only a WNOHANG result of zero authorizes a signal. Confirmed collection clears the
matching PID/start timestamp and attempts watcher removal. Unconfirmed ownership
is retained with a diagnostic and false return. Old watcher callbacks cannot
clear a different PID or fabricate a fresh completion status.

Existing case 761 now executes the extracted production routines with injected
process operations and real children, covering responsive/ignored TERM, error
classification, finite polling, watcher refusal and stale callbacks. Its 57
assertions pass locally. The metrics/archive-source cases also pass (145 combined
assertions across those three cases). Wider cases 762/763 require unavailable
local dependencies, including URI::Escape; they and the full suite must run on
the host. No full-suite success is claimed. No SQL, transaction, schema or service
change. Scheduling and syscall overhead may exceed nominal sleep budgets.

Next: checkpoint phase D across all documented owners. Achievement and archive
shutdown are now bounded at the reviewed paths, but this does not establish a
universal shutdown protocol for AsyncWorker consumers, scheduler and plugins.

## MB1227 — phase D checkpoint and plugin job ownership

Reviewed at `473a0b1b462f93ba631ddc906f34c44d4ce93d5f` (MB1226), matching
`snap_mediabot_v3_teuk_20261111_142227.zip`. Commit presence and inspected source
confirm implementation; no missing host test totals are inferred. This increment
changes documentation only. It does not declare phase D complete.

| Boundary | Delivered behavior | Remaining scope |
| --- | --- | --- |
| Connection output | NOTICE, paced PRIVMSG and deferred AntiFlood callbacks are retired when transport identity changes (MB1212–1214). | Final exit is a distinct boundary; physical loop removal can fail. |
| Nicklist timers | Exact registration retirement precedes independent stop/remove attempts (MB1218). | No universal retry or final-exit service was introduced. |
| Achievement children | Logical result ownership is separate from physical child ownership; accepted detached children remain tracked until collection; final shutdown polls within shared TERM/KILL budgets (MB1219–1225). | Unconfirmed collection stays explicit; this does not govern generic AsyncWorker children. |
| Archive child | Final exit and watcher refusal use bounded ownership checks and collection; late callbacks cannot clear another PID (MB1226). | Unconfirmed PID stays recorded; no claim of guaranteed collection under OS errors. |
| Scheduler/plugin jobs | Scheduler already exposes exact registration identity; plugin jobs retain name/clock records and lifecycle authorization gates. | Next: preserve exact ownership and failed cleanup records at the plugin/Scheduler boundary. |
| Generic AsyncWorker | Per-loop observational registry and asynchronous cancellation exist. | Review final-exit ownership separately; the active registry excludes finalized workers and is not a physical-child inventory. |

### Next runtime increment: plugin job registration ownership

Source inspection of [PluginManager](../Mediabot/PluginManager.pm)
`_mount_v3_jobs`, `_stop_v3_jobs` and `_remove_v3_jobs` finds that mounted records
contain a task name and clock, but no Scheduler registration identity. Stop and
remove operate by name. `_remove_v3_jobs` clears the entire mounted list even
when a remove returns false. Mount rollback also removes by name. These are
concrete source findings to reproduce, not a claim of a production incident.

[Scheduler](../Mediabot/Scheduler.pm) already provides `registration_id` and
`task_info`; [ShellWatch](../Mediabot/Partyline/ShellWatch.pm) `_remove_owned`
shows an existing exact-owner adapter. Reuse the established identity contract
where appropriate. Audit reentrancy inside Scheduler removal as well as the
caller: a pre-call identity check alone is not sufficient if cleanup replaces
the registration. Keep authorization, quarantine and lifecycle policy with the
manager; no general scheduler rewrite or new framework is required.

Acceptance for the next bounded patch:

1. Reproduce a same-name successor and a false/throwing removal against the real
   manager and Scheduler boundary before changing behavior.
2. Capture ownership at registration; old stop, unload and mount rollback must
   not stop or delete a successor. Preserve API v2 behavior and existing public
   task names, intervals and disabled-on-load behavior.
3. Retain enough ownership to diagnose and retry incomplete removal. Do not
   silently discard a still-owned task or report complete teardown on failure.
4. Keep existing entry/capability/enable/quarantine gates and test retained old
   callbacks after disable/unload; registration ownership complements these gates.
5. Extend [1072](../t/cases/1072_mb743_v3_events_jobs_lifecycle.t) and relevant
   [1091 diagnostics](../t/cases/1091_mb750_plugin_diagnostics.t) coverage instead
   of adding another historical test file. Cover normal lifecycle, rollback,
   repeated cleanup, reentrant replacement and failure recovery. Preserve native
   Scheduler integration and run the full suite once before the runtime commit.

After this boundary, checkpoint again before expanding scope. Generic worker
final-exit policy and DB timer cleanup remain candidates, not an instruction to
migrate every family. Phases B/C still have command-side writes and shared-cache
invalidation to review; phase E retains discovery/security/lifecycle authority.
Radio, YouTube, schema changes and a universal shutdown container remain outside
this increment. No runtime performance gain is claimed.

Validation for MB1227: documentation links and source symbols, snapshot/base
comparison, patch/reverse guards and the real commit script against a temporary
local remote. No runtime changes: do not rerun the full runtime suite solely for
this checkpoint. Host application/commit of MB1227 remains pending delivery.

## MB1228 — preserve Scheduler successors during cleanup

Base: `f92fb0903bf694030e243aaff161eb3e8c5e1793` (MB1227 on GitHub).
No newer snapshot was supplied; runtime source comes from that exact commit.
The existing host commit script remains separately hash-guarded.

The MB1227 audit's reentrancy prerequisite is now reproduced: both periodic and
calendar removal can lose a replacement registered by stop logging or loop
removal. The native Scheduler was invoked with deterministic loop/logger hooks;
the old implementation failed 20 assertions across the four scenarios, leaving
the replacement timer attached without its task record.

`Scheduler::remove` now rechecks the captured task reference after stop and after
loop removal. If nested cleanup already retired it, the outer call completes
without deleting the successor. Existing false returns for absent tasks and
stop/remove failures remain unchanged. The public signature is unchanged.

Existing case 575 now has 62 assertions, including retained callback inertness,
successor delivery and subsequent explicit cleanup. The local scheduler lane
passed 516 assertions across eight cases, including native IO::Async cases;
case 749 could not load JSON::MaybeXS locally. Plugin lifecycle/diagnostics
cases 1072 and 1091 passed 78 assertions. Full host acceptance remains pending.

This small prerequisite does not complete plugin-job ownership: the manager
still stores task names, clears failed removal records and rolls back by name.
Next apply the MB1227 acceptance contract there, including failed removal
recovery and exact registration capture. Do not mark those findings fixed by
this Scheduler change. No service, configuration, database or provider changes.

## MB1229 — incomplete plugin unload recovery

Base `d65f85b5c305276d8d1a9363563ad5f5b5a1bc96` (MB1228 on GitHub), matched
against `snap_mediabot_v3_teuk_20261111_182923.zip` for changed inputs.

The next bounded part of MB1227's acceptance contract is failure recovery.
Previously a false removal cleared mounted_jobs and unregister deleted the
plugin; an exception could abandon cleanup of later jobs. The persistent unload
could therefore record success while a task remained registered.

Now unresolved records stay on the disabled entry, other jobs are attempted,
and incomplete removal throws before persistent-state writing. Re-enabling or
replacing the partially unloaded entry is refused until unload is retried.
Native task_info confirmation of an absent task allows recovery after separate
operator cleanup. Command/event surfaces and late job callbacks remain retired.
No new retry timer, configuration, schema or API v2 lifecycle is introduced.

Existing case 1072 covers false/throwing/unavailable cleanup, partial progress,
retry, persistent-write suppression and activation/replacement refusal. Its
existing MB908 native fixture now injects IO::Async removal failure and verifies
actual notifier ownership, callback inertness and retry (including a task already
removed by the operator). Local targeted lane: 11 files, 404 assertions passed.
Full host acceptance remains pending; do not infer a host result from local tests.

Remaining: mounted task names still need exact registration identity at mount,
start/stop/remove and mount rollback. This patch does not claim same-name
successor protection in PluginManager; MB1228 only protects reentrant removal
inside Scheduler. Retaining failed records is the prerequisite for safely
changing that boundary. Generic workers and final-exit policy remain separate.

## MB1230 — exact plugin job ownership

Base `d8a690b9534da14d356bc22b7ffa5cbd6693a692` (MB1229 on GitHub), matched
against `snap_mediabot_v3_teuk_20261111_184619.zip` for changed inputs.

Native reproduction showed an old plugin stopping/removing a same-name successor,
activation starting that successor, and a retained old callback still executing.
The mounted record now contains the scheduler identity and exact callback
registration ID. All lifecycle operations check that identity; activation checks
again after start. Missing/superseded registrations are released without mutation,
while unknown identity or a different scheduler fails closed and retains cleanup
ownership. Existing API v2 behavior, task names, intervals and policy gates stay.

Mount publishes its owned records incrementally. A throwing add is inspected for
its exact callback registration, and rollback uses the same ownership-aware
removal path as unload. MB1229 failure retention/retry remains active. A
replacement during the handler revokes old output and subsequent-channel dispatch.
The native Scheduler registration_id/task_info contract is now required for v3
jobs; seven deterministic test doubles expose that existing native contract.
Pre-change in-memory records without identity are not guessed from their names;
use ordinary fresh process/plugin initialization when adopting this code.

Existing case 1072 and MB908 fixture cover lifecycle replacements, retained
callbacks, add/start replacement, failed mount/start rollback, post-add exceptions,
incomplete rollback recovery and replacement during output. No new historical
case file was introduced. Local targeted acceptance: 24 files, 981 assertions
passed, including Scheduler native cases. Full host suite/commit remains pending.

This completes the bounded plugin-job ownership/recovery implementation selected
in MB1227, subject to host acceptance. It does not complete all phase D. Next:
checkpoint remaining generic-worker/final-exit questions and phases B/C data
access responsibilities before selecting another family. Do not append another
shutdown migration automatically or introduce a universal resource framework.

## MB1231 — checkpoint and channel rule write boundary

Reviewed base `9508ecbf31e5993bba0430e32ac99b061263e987` and supplied snapshot
`snap_mediabot_v3_teuk_20261111_190100.zip`. MB1230 is now committed on
origin/master. Its full host test totals are not supplied here and are not
inferred from that commit. Earlier pending-acceptance notes describe delivery time.

| Area | State after review | Next decision |
| --- | --- | --- |
| A / Partyline | Plugin administration extraction delivered. | No further split without a concrete boundary and tests. |
| B / Helpers | Output admission delegated; broader responsibilities remain. | Preserve compatibility delegates; do not split by file size alone. |
| C / channel rules | Reader extracted; command still owns UPDATE and cache invalidation. | Selected next: isolate the UPDATE behind the existing domain module. |
| D / ownership | Connection output, nicklist, achievement/archive and plugin-job increments delivered. | Generic worker final-exit coordination and DB timer cleanup remain review candidates, not established leaks. |
| E / PluginManager | Persistence/diagnostics extracted; lifecycle authority retained. | Keep exact registration ownership and incomplete-unload recovery together. |

### Selected next increment: flood-rule UPDATE only

Source: [ChannelCommands](../Mediabot/ChannelCommands.pm),
`setChannelAntiFloodParams_ctx`, and [FloodRules](../Mediabot/Channel/FloodRules.pm),
`read`. Extract only the UPDATE into this existing data-access component. It
receives a DBI-compatible handle, channel ID and raw validated values; no bot,
transport, logger, clock or cache. Characterize behavior before choosing its
result shape; distinguish prepare failure from execute failure for diagnostics.
This is a structural change, not a newly demonstrated production bug.

Keep Master authorization, channel resolution, argument validation, AntiFlood
chanset gates and exact replies in the command. Keep invalidation of `_af_params`
and `_chan_flood_conf` for canonical and requested spellings there, after the
same successful execute/finish boundary. No new cache, normalization, transaction,
row creation, schema change or automatic retry is part of this increment.

Preserve DBI truth semantics including `0E0`, bind order, finish call order,
exception identity and failure diagnostics. Failed prepare/execute must not
invalidate caches or emit success; a thrown finish must not silently become
success. Do not fix input edge cases or zero-row semantics incidentally.
The no-argument display JOIN by channel name is a separate read contract; leave
it intact. Admission reader failure policy remains unchanged.

Extend existing [case 398](../t/cases/398_mb162_badword_and_afparams_cache_invalidation.t)
with actual component/command behavior, not just source-string checks. Cover
success, false prepare/execute, thrown DBI operations, `0E0`, cache-key isolation,
permission/validation refusals and unchanged display behavior. Keep reader and
admission cases 627/337 and native command routing in targeted acceptance, then
run the full suite once before the runtime commit. Avoid another historical
case file merely for this extraction.

MB1231 itself changes documentation only. Validate relative links, reviewed
symbols and the guarded patch/commit workflow; no runtime suite is needed for
this checkpoint. The write extraction is planned, not implemented by MB1231.

## MB1232 — channel flood-rule UPDATE boundary

Base `2325530f6eaddf8c75d6b89330aacc0bf20c6d3f` (MB1231), matched against
`snap_mediabot_v3_teuk_20261111_190746.zip` for changed inputs.

`Channel::FloodRules::write` receives the DB handle, channel ID and validated raw
values; owns SQL and binding; returns prepare_error, execute_error or updated.
It deliberately hands the statement back to the command after execute. The
command retains diagnostics and finish: execute failure historically logs before
finish, success finishes before invalidating both cache spellings and replying.
This keeps the domain module free of logger/transport callbacks without moving
observable cleanup order. Exceptions propagate unchanged and 0E0 stays successful.
The historical no-argument JOIN, input validation and authorization are unchanged.
This bounded extraction does not complete all phase C or create a generic DB API.

Existing case 398 now invokes the real command with DB/IRC dependencies replaced
at their boundaries, instead of simulating cache refresh and manually deleting
keys. Ninety behavioral assertions passed against the unchanged command first;
the same checks cover the extracted implementation. Additional component checks
verify SQL/binds and explicit statement handoff. No new case file is introduced.
Local six-file lane: 516 assertions passed. Native case 1306 also passed its
first 131 assertions but could not complete: Config::Simple is absent locally
when loading the full bot. This is not a passing integration case. The package
includes it in host targeted acceptance; full acceptance/commit remain pending.

Next: assess the display query as a separate contract, retaining lookup by name,
missing-row response and diagnostic/finish ordering. Do not replace it with the
admission reader just because both query CHANNEL_FLOOD. Remaining phase D review
questions stay in the MB1231 checkpoint; no automatic shutdown migration.

## MB1233 — operator flood-rule display read

Base `cdbdbee69a0bbf666f304e9e91c4f4fab8525419`, matched against supplied
`snap_mediabot_v3_teuk_20261111_192531.zip` for changed inputs. MB1232 is
committed on origin/master; no host assertion totals are inferred from that fact.

`Channel::FloodRules::read_for_display` owns the existing SELECT/JOIN, exact
channel-name binding and fetch. It returns found/missing/error plus its statement.
The command retains Master authorization, channel resolution, diagnostic and
notice rendering, then finish. In particular, notices precede finish, while
false execute is diagnosed before finish. Thrown prepare/execute/fetch or notice
does not gain an implicit cleanup call. DBI 0E0 remains truthy; null values still
render as zero. No new cache, transaction, retry or normalization is introduced.

This separate method is deliberate: admission's read uses channel ID, owns its
finish timing and has a different failure policy. Do not substitute one for the
other. The UPDATE extraction and existing cache invalidation remain unchanged.

Case 398's expanded native command checks passed against the unmodified command
before extraction (191 assertions), including literal percent/underscore in the
name, missing/null rows, singular/plural output, false results, exception identity,
notice failure and complete operation ordering. Case 44 now checks the SQL's
actual owner. No additional historical test file was introduced.

Local targeted lane: six files, 599 assertions passed. Full target-host
acceptance and commit remain pending; native integration case 1306 still needs
the full bot dependencies absent from this local environment.
After acceptance, checkpoint the bounded channel data-access pilot: antifloodset
read/write now have an explicit owner, but other channel info/chanset queries and
broader Helpers boundaries remain. Select further work from inspected call sites;
do not claim all phase C complete or automatically move every SQL statement.

## MB1234 — channel data-access checkpoint

Reviewed base `7b4785676667d3111fdca084b2a8137531f69eb8` (MB1233 on
origin/master), matched against `snap_mediabot_v3_teuk_20261111_194142.zip`.
MB1232 and MB1233 are committed; missing detailed host test reports are not
reconstructed from those commits. This delivery changes documentation only.

### Boundaries now present and still open

| Caller / source | Current boundary | Decision |
| --- | --- | --- |
| [OutputPolicy](../Mediabot/IRC/OutputPolicy.pm), `checkAntiFlood` | FloodRules ID reader; policy owns defaults/cache/admission fallback. | Retain existing MB1210 contract. |
| [ChannelCommands](../Mediabot/ChannelCommands.pm), `setChannelAntiFloodParams_ctx` | FloodRules UPDATE and display JOIN; command owns permissions, diagnostics, replies and statement finish. | Bounded pilot implemented in MB1232–1233. |
| ChannelCommands, `userChannelInfo_ctx` | Separate ID query including notification and LIMIT 1. | Defer; neither admission nor display reader is an interchangeable replacement. |
| [Helpers](../Mediabot/Helpers.pm), `setChannelAntiFlood` | Chanset bootstrap SELECT/INSERT/re-read plus notices and insert ID. | Defer as a separate mutation contract; do not turn the UPDATE into an upsert. |
| [Sender](../Mediabot/IRC/Sender.pm), `_badwords_for_channel` | SQL/fetch/validation mixed with cache, diagnostics and fallback in IRC transport. | Selected next: extract only its complete database read. |

The next boundary is selected for its transport/data-access separation and
existing native fault coverage, not because this review establishes a new bug.
Do not chase every CHANNEL_FLOOD statement merely to make the table appear in
one file. Phases B/C remain incremental; phase D's generic worker final-exit and
DB timer questions remain open review candidates, not confirmed resource leaks.
The bounded A/E pilots and plugin-job ownership work remain delivered.

### Next implementation: outgoing badword read

Introduce a small channel-domain reader receiving a DBI-compatible handle and
the original target name. Move the existing SELECT/JOIN, fetch loop, row/value
validation and statement cleanup there. Return a complete list or explicit
failure; never expose a partial list as successful data. It must not depend on
Helpers, the bot, IRC transport, logger, metrics, clock or a new cache.

Retain `_badwords_for_channel` as the policy owner: lower-case cache identity,
original SQL bind/wire target, current 300-second freshness boundary, and shared
PRIVMSG/ACTION behavior. On failure keep the old list AND its original age,
retry on the next expired lookup, and keep initial diagnostic-and-send behavior
when there is no confirmed cache. A successful empty list is valid cache data.
Do not borrow AntiFlood's global-only fallback or its negative-cache policy.

Preserve these observed database semantics before considering improvements:

- False prepare/execute, thrown operations, invalid rows/reference values and
  a fetch error after partial rows fail the whole read.
- Undefined word values are skipped; ordinary scalar words retain current `lc`
  normalization, ordering and duplicates. No new regex or Unicode folding rule.
- Capture complete-read success before finish, which can clear driver errors.
  Attempt finish for an acquired statement; a finish exception is currently
  contained and does not turn a completed read into failure.
- Keep the existing diagnostic and query-error metric at the policy boundary;
  logger/metric failures remain contained. Do not leak database details to IRC.

Extend [native output case 1306](../t/cases/1306_mb881_irc_output_policy.t)
and its existing fixtures. Preserve RaiseError 0/1, partial-fetch failure,
empty-list recovery, exact TTL boundary, mixed-case cache identity, unrelated
channel isolation, add/remove invalidation and unchanged wire/history targets.
Add direct reader checks only where native coverage cannot observe the contract.
Run the targeted output/command lane, then the full suite once before commit.
The new reader should load without pulling in the bot or transport graph.

MB1234 validation is documentation links/source symbols and guarded patch flow;
no bot test suite is needed for these documentation-only edits. The reader
extraction is the next implementation, not a runtime change in this checkpoint.

## MB1235 — complete outgoing badword reads

Base `289e8487ae9d2e30fc87910cea6422d6203f99d4` (MB1234 on origin/master).
No newer snapshot was supplied; tracked inputs come exclusively from this Git
revision. The existing commit.sh hash guard is retained from the last supplied
snapshot, not reconstructed from GitHub.

`Channel::Badwords::read` owns the unchanged query, literal target bind, fetch
validation, lower-case scalar list and finish attempt. It returns only a complete
successful list (including an empty list) or explicit failure without partial
words. It has no bot, cache, clock, logger or transport dependency.

Sender retains the current 300-second freshness rule, lower-case cache identity,
original query/wire target, last-confirmed words and age after failure, initial
empty fallback, retry and existing diagnostic/metric behavior. Successful read
status is still captured before finish; finish exceptions remain contained and do
not invalidate a completed read. No command write or invalidation code changes.

The existing MB881 fixture now has 146 fault/policy assertions that passed against
Sender before extraction and after it. Existing case 1306 invokes these checks;
o new historical case file is introduced. Existing case 1304 verifies cold module
loading without Helpers or provider dependencies. The full native case 1306 needs
full bot dependencies absent locally and remains required on the target host.
Full host acceptance and commit/push are pending at package preparation.

Next: review add/remove command data access and its no-op/invalidation semantics
before moving writes; do not change storage collation, matching, TTL or fail-open
versus confirmed-rule behavior as a side effect. Phase C remains incremental.

## MB1236 — badword command data access

Base `043310dd85bc12f11b552015d8e0f8706dabdd88` (MB1235 on origin/master),
matched against `snap_mediabot_v3_teuk_20261111_200023.zip` for changed inputs.
MB1235 is committed; no detailed host assertion total is inferred from its commit.

Channel::Badwords now owns the exact add/remove lookup queries, INSERT and DELETE.
The command-specific functions return DBI result, statement and original SQL for
existing diagnostics. Their private executor is local to this domain, not a new
generic database abstraction. Exceptions and DBI 0E0 truth remain unchanged.

Commands still own fetch/finish sequencing, authorization, raw-word normalization,
no-op replies and audit messages. Existing add no-op replies/audits before finish;
remove no-op finishes before replying. Mutation success invalidates lower-case,
canonical and typed cache keys before reply/audit/finish, as before. A finish or
notice exception after mutation does not undo the already-completed invalidation.
No new transaction, upsert, retry, row-count interpretation or collation change.
The outgoing reader and last-confirmed cache policy are unchanged.

Existing MB881 fixture gains 134 command assertions, passing on the old handlers
before extraction and the new ones afterwards. Together with MB1235's 146 read
checks, the offline/native shared fixture has 280 assertions. Case 1306 runs both;
no new historical test file is added. Full native integration still requires bot
dependencies absent locally and remains mandatory on the host before commit.

Next: checkpoint the channel badword pilot after acceptance. The read/write SQL
boundary is implemented; do not merge command ownership or cache policies simply
because they share the table. Reassess the remaining B/C and D priorities before
starting another family. Full host acceptance and commit remain pending here.

## MB1237 — badword pilot and DB timer review

Reviewed `8907a26c0dadee96622a23c24c678236e5763070` (MB1236 on
origin/master) against `snap_mediabot_v3_teuk_20261111_201401.zip`.
MB1235/MB1236 are committed; missing host assertion totals are not inferred.
This checkpoint changes documentation only, not timer or database behavior.

### Delivered boundaries and remaining scope

| Area | Bounded work delivered | Remaining decision |
| --- | --- | --- |
| A | Partyline plugin administration extracted. | Further parsing/rendering separation only with a concrete need. |
| B | Helpers output admission delegated. | Wider dependency reduction remains open; avoid cosmetic file splitting. |
| C | Flood-rule admission reader and antifloodset read/write; badword outgoing reader and command SQL. | Pilots complete as implementations. Chanset bootstrap and chaninfo retain separate contracts; no automatic bulk extraction. |
| D | Output/nicklist retirement, achievement/archive ownership and plugin-job recovery/identity. | Next: DB timer reload publication under reentrant callbacks. Generic-worker final-exit coordination remains separate. |
| E | Plugin persistence and diagnostics separated. | Keep lifecycle/capability authority in PluginManager. |

The badword domain owns SQL, not command authorization or cache authority.
Sender still owns confirmed-rule fallback; commands still own no-op responses,
mutation invalidation and their different finish order. Do not merge these
policies or add a generic repository abstraction to declare all phase C finished.

### Next review: DB timer reload publication

Source: [DBCommands](../Mediabot/DBCommands.pm), `onStartTimers` and
`_stop_all_runtime_db_timers`. Existing [case 403](../t/cases/403_mb164_onstarttimers_stage_fresh_before_publish.t)
already exercises native Periodic timers, SQLite, setup rollback and public wiring.
Reuse it rather than creating another historical case file.

Observed protections: a complete DB snapshot precedes staging; add/start failure
rolls back fresh attempts and keeps the old set; tick callbacks compare exact
published timer identity. Retirement detaches hTimers before stop/remove.
These protections must remain. The final publication currently copies the staged
set into hTimers after calling retirement; no reload-generation check is visible
at that publication site. This is a review hypothesis, not a reproduced defect.

The next increment should first inject a nested reload or replacement through
logging, timer add/start and old stop/remove seams, and retain callbacks. Determine
whether an older attempt can retire or overwrite a later published set. Include
nested failure as well as success; record which invocation retains authority.
If a failure is reproduced, make the smallest ownership fix with these criteria:

- A superseded attempt cannot publish over or stop a later authorized timer set.
- Losing attempts clean only their own staged notifiers, including partial setup;
  cleanup callbacks cannot revive obsolete publication authority.
- Failed DB reads/setup retain the working set and current return/diagnostic
  contracts unless an explicitly documented correction is necessary.
- Queued obsolete ticks stay inert; normal startup, empty snapshots and sequential
  reconnect still publish once and execute each scheduled command once.
- Keep SQL/schema, command dispatch, responder retirement, final-exit policy and
  unrelated Scheduler jobs outside this change. Do not add a universal stop-all.

Characterize behavior before choosing registry identity versus a generation
mechanism; neither is mandated by this checkpoint. If the suspected sequence is
already safe, record that evidence and choose another concrete remaining gap
instead of manufacturing a runtime fix. Target native case 403 and adjacent
DB-timer safety/IRC-write cases, then the full suite once for a runtime change.

MB1237 checks documentation links and reviewed source symbols plus guarded patch
application/commit flow. No bot suite is required for this documentation-only
checkpoint. The next timer investigation and any fix are not implemented here.


## MB1238 — Reentrant DB timer publication

Prepared against MB1237 commit `10a311c924985506792a5e5d95bcfe499c77b7d0`.
The MB1237 hypothesis is reproduced with the real DBCommands module, native
IO::Async Periodic timers and a private SQLite database: an older invocation
can retire/overwrite a nested successful publication. Retirement-time nesting
can also leave the overwritten timers attached but unregistered.

The fix records successful publication identity. Each attempt checks that
identity before setup, after add/start and after retirement. A superseded
attempt returns zero and cleans only its own attempted timers. An empty nested
publication also wins. Nested DB/setup failures do not change publication
identity, so a still-authorized outer attempt can complete. Cleanup reentrancy
cannot restore an obsolete attempt's authority. This covers nested reloads;
it does not redefine arbitrary direct hTimers writes or operator mutations.

Existing [case 403](../t/cases/403_mb164_onstarttimers_stage_fresh_before_publish.t)
uses [the native fixture](../t/lib/MB1238TimerReload.pm): 288 assertions, with
58 failures against the unchanged base and all passing with the fix. Four
adjacent cases pass 58 assertions locally. Full case 403 and XAUTH case 1223
need missing full-bot dependencies locally; their host acceptance and the full
suite are pending. The delivery requires both before commit/push. No new
historical case file, schema change or service action is introduced.

Next review: timer tick callbacks check ownership before logging, then write.
Investigate replacement during that log callback using retained native ticks;
do not assume a defect or expand final-exit handling without reproduction.
Broader phases B/C/D and generic-worker exit coordination remain open.


## MB1239 — Timer authority after logging

Base: MB1238 R2 commit `35bdd3b4579b42ac3654525998a21ad29f66f3d8`, verified on
GitHub and matching tracked files in the supplied 21:23:32 snapshot. R2 confines
native timer scenarios to case 403's existing child and preserves unrelated
loop handles. This confirms the committed revision, not an unseen full-suite
acceptance transcript.

The selected tick-time hypothesis is reproduced in both onStartTimers and
mbAddTimer_ctx callbacks: logging can synchronously replace or retire a timer,
yet its already-running callback still sends the old command. Eight of 102 new
native assertions fail on the base. The fix rechecks exact hTimers identity
after logging, before entering the existing guarded IRC writer. It does not
retry a command or execute the replacement timer early. A failed reload leaves
the same timer authorized; logger exceptions retain their original identity.

The existing native fixture now covers both entry points, normal delivery,
replacement (including identical name and command), empty reload, explicit
retirement, failed DB read, throwing logger and retained stale ticks. All 390
reload/tick assertions pass locally, as do 65 assertions in five adjacent cases.
Case 403 remains in its native child; no extra process, sleep or historical
case file. Full case 403/XAUTH integration requires the host's full-bot
dependencies and the complete host suite remains mandatory before commit.

This closes the two selected DB-timer reentrancy gaps, not a universal resource
lifecycle audit. Next checkpoint: review remaining phase B Helpers dependencies
and select one bounded boundary with existing behavioral tests. Keep arbitrary
operator mutation during setup and generic-worker final-exit coordination as
separate open questions; do not broaden this tick fix into a timer framework.


## MB1240 — Helpers local version boundary

Reviewed at MB1239 commit `8437a8901e42da62238c55cd68718e0b1f43507a`,
matching tracked files in the supplied 2026-11-11 21:50:52 snapshot.
MB1238 R2 (`35bdd3b4`) and MB1239 (`8437a890`) are committed on GitHub.
Their full host acceptance transcripts were not supplied; do not invent totals.
This checkpoint implements no runtime extraction or new timer behavior.

### Boundary review

| Candidate | Observed coupling | Decision |
| --- | --- | --- |
| Local version identity in [Helpers](../Mediabot/Helpers.pm), `_cached_local_version`, `_read_local_version`, `getLocalVersion` | [Remote](../Mediabot/Version/Remote.pm) explicitly requires Helpers when local hooks are absent, although local identity needs only file access, normalization, logging and existing bot cache. | Selected. Small domain adjacent to existing Format and Remote modules; preserve the facade. |
| Authentication/user lookup in Helpers, `get_user_from_message`, `get_user_from_whois` | Shared user caches, hostmask resolution, authentication and DB policy. | Defer; not a mechanical utility extraction. It needs a separate security and invalidation contract. |
| Resolver/whereis in Helpers, `resolve_ctx`, `whereis_async` | Operator responses, asynchronous workers and transport failure behavior. | Defer; larger lifecycle/command boundary than local identity. |
| Existing output/archive delegates | Helpers already forwards to owning modules. | Retain compatibility; moving forwarding wrappers alone would not reduce ownership ambiguity. |

### Selected implementation scope

Introduce a small local-version component (proposed `Mediabot::Version::Local`)
that owns local reading/cache fallback, leaving public Helpers entry points and
imports compatible. The success criterion is that the component can serve local
identity without loading Helpers, HTTP, DBI or AsyncWorker. Remote's local fallback
should use it when no legacy override is installed, instead of requiring Helpers.
Existing overrides remain optional call-time hooks; do not turn them into mandatory
reverse imports or recursion between two forwarding wrappers.

[Format](../Mediabot/Version/Format.pm) already owns normalization and comparison.
Keep that ownership. `versionCheck` remains command routing/presentation; remote
URLs, worker budgets and error categories stay in Remote. No version grammar,
network retry policy, VERSION contents or release process change belongs here.

### Contracts to characterize before moving code

- **Path lifetime:** Helpers currently resolves its absolute source path at module
  load and derives VERSION from that tree. Preserve foreign-cwd behavior and the
  moment the path becomes fixed, including Helpers-first versus Local-first load
  order. Do not accidentally derive the root one directory too shallow after
  moving into Version/. Explicitly test symlink/source-tree resolution before
  choosing how the facade anchors the path; do not silently change it.
- **File semantics:** read the first line with the current I/O layer and normalize
  through the existing hook. Characterize absent/empty files, whitespace, the
  Undefined sentinel and malformed values; do not mix encoding/BOM fixes into
  this structural change. Reading at startup stays local-only.
- **Cache semantics:** usable disk identity refreshes main_prog_version. An
  unusable read falls back to the last usable cached value; the sentinel must
  not poison that value. The cache accessor does not perform disk/network I/O.
- **Hooks and diagnostics:** preserve Helpers normalizer/read/local/cache hook
  overrides where they are used, arguments, return values and logger order.
  Characterize logger exceptions and existing undef/non-object call behavior;
  do not introduce unrelated validation changes or silently suppress failures.
- **Update identity remains distinct:** [Update::_read_local_version](../Mediabot/Update.pm)
  resolves the selected update project directory, opens with UTF-8, and returns
  undef rather than the same sentinel policy. Do not merge it just because it
  has a similar function name. Update completion/deployment ownership is separate.

### Validation and delivery gates

Extend existing [case 606](../t/cases/606_mb388_release_version_identity.t) and
[case 607](../t/cases/607_mb389_local_startup_semantic_version_compare.t).
Case 606 currently asserts lexical declarations in Helpers: replace those
location checks with actual source-root/cwd behavior while retaining its existing
async fallback checks. Case 607 already tests foreign cwd, no HTTP startup,
Format/Helpers load orders and call-time parser overrides. Extend its existing
bounded cold probes rather than adding a historical case per module.

Use temporary source trees/files and actual components; never rewrite the live
repository VERSION to simulate failure. Compare behavior before/after the move.
Include [539](../t/cases/539_mb317_version_check_async_nonblocking.t),
[818](../t/cases/818_mb638_remote_version_diagnosis.t),
[821](../t/cases/821_mb641_version_worker_terminal_truth.t) and
[834](../t/cases/834_mb652_version_asyncworker_migration.t) in targeted acceptance:
834 explicitly overrides the Helpers cache accessor. Test all relevant load
orders so passing without Helpers does not break historical integration with it.
Run the full suite once on the host before committing the eventual runtime patch.

MB1240 itself changes documentation only. Check links/source symbols and guarded
patch/commit workflow; do not spend another full bot suite on this checkpoint.
Phase B remains open until the extraction is implemented and accepted. Phases C/D
still include broader domain boundaries and generic-worker final-exit questions;
this selection does not declare the architecture roadmap complete.


## MB1241 — Local version component

Base: MB1240 commit `c1cc262b9ee59e6cc69101e3c24a22e10586736e` from GitHub.
No newer snapshot was supplied; commit.sh is guarded against the last supplied
21:50:52 snapshot. [Local](../Mediabot/Version/Local.pm) owns first-line reading,
normalization through an explicit callback, cache access and fallback policy.
It has only core file/path dependencies plus Format; no reverse Helpers import.

Helpers remains the compatibility adapter. It deliberately retains its original
load-time absolute source anchor, including symlink resolution, and passes that
path to Local. Moving this anchor into a lazily loaded helper would change
behavior after cwd/source-tree changes. Normalizer and reader adapters resolve
legacy symbols when invoked, even if a logger replaces a hook during the call.
The standalone Local entry point anchors its own tree when the component loads.

Remote prefers existing Helpers hooks when present; otherwise local/cache
fallback uses Local without importing Helpers. Network requests, TLS, worker
limits, versionCheck rendering, comparison grammar and Update's different
project-tree reader remain unchanged. This is one bounded phase B extraction,
not elimination of every bidirectional compatibility hook.

[Case 607](../t/cases/607_mb389_local_startup_semantic_version_compare.t) uses
[the shared native fixture](../t/lib/MB1241LocalVersion.pm) with independent
temporary trees and the existing bounded cold-probe helper. It covers first
line/whitespace, non-semantic usable labels, empty/missing/Undefined input,
foreign cwd, a symlinked Helpers source, cache immutability, exact diagnostics,
logger exception identity, hook overrides and six load/entry configurations.
[Case 606](../t/cases/606_mb388_release_version_identity.t) replaces three
source-location checks with this behavioral coverage; its runtime checks remain.

The 64 legacy assertions pass on the unchanged base. All 189 extended assertions
pass after extraction. Four executable targeted cases pass 264 assertions locally.
Cases 818 and 834 fail on both base and candidate because HTML::Entities is absent
from this environment; this is not a passing integration lane. The delivery runs
all six targeted cases and one full host suite before commit/push. No host result
is claimed until supplied. No schema, runtime configuration or service action.

Next review: remaining Helpers versionCheck presentation/routing is still a
command concern, while Remote owns transport. Inspect its callers and existing
539/607 tests before deciding whether another extraction is useful. Do not move
small wrappers merely to shrink the file, and do not combine this with Update's
separate deployment identity or generic-worker shutdown work.


## MB1242 — Version command presentation

Base `55eedd9e7fdc4de524f9ca0dbe36ac419822b29b` (MB1241 on origin/master)
exactly matches the tracked files in `snap_mediabot_v3_teuk_20261112_111856.zip`.
MB1241 is committed; its full host assertion total was not supplied and is not
inferred from that commit.

The caller review found the core `version` dispatch in
[Mediabot](../Mediabot/Mediabot.pm) and historical Helpers imports. The command
has a distinct contract: emit cached/local identity first, audit, then request
an optional remote follow-up. This belongs neither to file policy nor HTTP.
[Version::Command](../Mediabot/Version/Command.pm) now owns that orchestration
and wording. It imports no Helpers, file reader, HTTP, DBI or worker. Context
still owns target routing. Six explicit callbacks supply normalization, cached
identity, local read, comparison, audit and remote submission.

Helpers::versionCheck remains the exported adapter. Callback closures resolve
historical functions at invocation time, including an audit replacing the remote
hook and a comparator replaced before deferred completion. No production caller
is redirected away from this compatibility surface. Local, Format, Remote,
Update, remote completion/lifecycle and command permission checks are unchanged.
The no-loop synchronous compatibility path still belongs to Remote; the command
extraction does not promise to make that path asynchronous.

The same 135 behavioral assertions pass through actual Helpers before and after
extraction. The standalone component passes 134 assertions. These check immediate
versus deferred/inline completion, missing and invalid identity, remote ordering,
exact messages/audit arguments, fallback cache and exception identity at reply,
audit, submission and comparison. Submission returning false still leaves the
historical command return of 1; no retry or duplicate-completion policy is added.
Existing [case 539](../t/cases/539_mb317_version_check_async_nonblocking.t) runs
[the fixture](../t/lib/MB1242VersionCommand.pm) without a new historical case file
or sleep. Its worker/startup checks remain; core case 609 follows the new owner.

Five executable targeted cases pass 555 assertions locally. The wider seven-case
lane has 31 failures in cases 818/834 because loading External requires the absent
IO::Socket::SSL dependency here; it is not a passing lane. The package requires
all seven cases and one full suite on the target host before commit/push.
No full host acceptance, schema/configuration/service change or speedup is claimed.

Next: checkpoint the version domain (Format, Local, Remote, Command) and inspect
remaining phase B/C candidates against concrete coupling. Do not extract the
remaining small facade delegates for line-count reduction. Authentication lookup
and its cache invalidation need an explicit security contract before moving;
generic-worker final-exit coordination remains a separate phase D investigation.


## MB1243 — Version checkpoint and chaninfo read

Reviewed at `2db3d45be89332d731874aca71f298325975ef9f` (MB1242 on
origin/master), matching all tracked files in the supplied
`snap_mediabot_v3_teuk_20261112_115451.zip`. MB1241 (`55eedd9e`) and
MB1242 (`2db3d45b`) are committed. Their complete host acceptance transcripts
were not supplied; no assertion counts are inferred. This is a documentation
checkpoint, not a runtime extraction or a claim that phase B is complete.

### Version domain after the bounded split

| Owner | Responsibility retained | Compatibility boundary |
| --- | --- | --- |
| [Format](../Mediabot/Version/Format.pm) | Normalization, grammar and comparison. | Existing optional Helpers parser/comparator hooks remain call-time. |
| [Local](../Mediabot/Version/Local.pm) | First-line file identity and cached fallback. | Helpers supplies its historical path anchor and hooks; Update keeps its distinct project reader. |
| [Remote](../Mediabot/Version/Remote.pm) | Remote VERSION requests, diagnostics and AsyncWorker adaptation. | Optional Helpers hooks remain; no-loop synchronous fallback is unchanged. |
| [Command](../Mediabot/Version/Command.pm) | Immediate reply, audit and remote follow-up presentation. | Helpers supplies callbacks; Context owns reply routing; core dispatch still uses versionCheck. |

[539](../t/cases/539_mb317_version_check_async_nonblocking.t),
[606](../t/cases/606_mb388_release_version_identity.t),
[607](../t/cases/607_mb389_local_startup_semantic_version_compare.t) and
[609](../t/cases/609_mb391_core_command_release_contract.t) retain native facade,
path, presentation and wiring coverage. The current modules clarify ownership;
further moving small Helpers forwarding wrappers would not add a useful boundary.

### Candidate review and next bounded implementation

- **Selected: chaninfo's antiflood parameter read.**
  [ChannelCommands::userChannelInfo_ctx](../Mediabot/ChannelCommands.pm) still
  prepares an ID-based CHANNEL_FLOOD SELECT after reading its flags. The domain
  already has [FloodRules](../Mediabot/Channel/FloodRules.pm), but neither its
  admission read nor its operator name-based display read has this exact contract.
- **Defer whole chaninfo extraction.** Owner metadata, flags, Master-only key
  disclosure and response/audit sequencing are command responsibilities. Moving
  all three queries at once would unnecessarily enlarge this increment.
- **Defer authentication/cache extraction.** Helpers::get_user_from_message
  combines a five-second hostmask cache, lazy Auth/User construction and identity
  lookup; getIdChannelSet has separate 120-second positive/negative caching.
  They require their own invalidation/security contract, not mechanical copying.
- **Keep generic-worker final-exit coordination separate.** Existing phase D
  inventory remains authoritative; no universal shutdown coordinator is added.

Add a narrowly named FloodRules reader for chaninfo, receiving only the DB handle
and channel ID. Preserve the exact five-column SELECT (nbmsg_max, nbmsg, duration,
timetowait, notification), bound ID and LIMIT 1. Do not substitute the existing
three-column read or the name-based JOIN. Do not normalize DB values, interpret
0E0 as failure, introduce caching or change admission defaults.

Before implementation, characterize the actual userChannelInfo_ctx handler and
compare the same scenarios after extraction. Existing
[case 398](../t/cases/398_mb162_badword_and_afparams_cache_invalidation.t)
already has native FloodRules/ChannelCommands fixtures and is the first candidate
for extending coverage without another historical case file. Its current
antifloodset tests do not by themselves prove chaninfo's distinct contract.

Required behavior and failure matrix:

- Preserve explicit-channel versus Context-channel selection, original target
  spelling, cache object/id validation, notice target and final audit arguments.
- Main owner lookup remains first. Missing owner or failed main query must not
  launch flags/flood reads. Preserve public notices and authenticated Master-only
  modes/key/autojoin disclosure, including denied/throwing level checks.
- No nonempty flag means no flag notice; only the existing case-insensitive
  /AntiFlood/ match triggers flood reading. Do not tighten matching in this refactor.
- The flags statement finishes before its notice; flood success fetches, replies
  (including the exact missing-row text), then finishes, then audits. Notification
  uses existing Perl truth for ON/OFF. Preserve undefined/raw-value behavior.
- False flood prepare/execute logs the same query diagnostic and reaches final
  audit without a flood notice or new finish call. Exceptions from prepare,
  execute, fetch, notice, finish or logger retain identity and historical order.
- Keep DBI diagnostic tests isolated from real DBI magic and preserve pre-existing
  state. Retain every existing admission/display/write test in case 398/627.

The reader may return its original statement and SQL for command-owned cleanup
and diagnostics, following the existing domain pattern; do not hide exceptions
or add a generic database abstraction. Any cleanup improvement discovered during
characterization needs a separately justified behavior change, not a silent fix.
Target native chaninfo plus existing FloodRules tests, then run the complete suite
once before the eventual runtime commit. MB1243 itself needs documentation
link/symbol and guarded patch/commit checks only; no full bot suite is required.


## MB1244 — Chaninfo antiflood reader

Base `a9343f0485423ec5f364304ad45a355aca73afe6` is MB1243 on origin/master.
No newer snapshot was supplied; the existing commit.sh remains guarded against
the supplied 2026-11-12 11:54:51 snapshot. MB1243 is committed; no unprovided
host test results are inferred.

[Channel::FloodRules::read_for_channel_info](../Mediabot/Channel/FloodRules.pm)
owns chaninfo's exact five-column ID-based SELECT, execute and fetch. It returns
found/missing/error, the original row/statement and the original SQL text. No
normalization, defaults, cache, logger, bot or transport is introduced. Existing
admission and name-based display readers are deliberately unchanged.

[ChannelCommands::userChannelInfo_ctx](../Mediabot/ChannelCommands.pm) still owns
channel selection and existence/id checks, owner and flag reads, Master-only
key/mode/autojoin disclosure, notices, SQL diagnostics, finish and final audit.
In particular, false prepare/execute still logs without a new finish attempt;
success (including a missing row) notices before finish. DBI 0E0 stays true.
Thrown DBI/notice/logger/finish failures propagate unchanged. Undefined numeric
values retain their existing interpolation warnings; this extraction does not
silently turn them into zeros or repair legacy cleanup behavior.

[Case 398](../t/cases/398_mb162_badword_and_afparams_cache_invalidation.t) invokes
[the actual-command fixture](../t/lib/MB1244Chaninfo.pm). Its 32 scenarios cover
explicit/context targets, owner/cache/id failures, authenticated/denied/throwing
Master checks, flags and substring matching, missing/raw/undefined flood values,
notification truth and DBI/callback faults. All 358 assertions pass on the old
command and after extraction. The complete operation/notice/diagnostic traces
also match the baseline. DBI diagnostics use a localized scalar slot, not a write
to real DBI magic. Existing case 398 behavior checks remain intact.

The targeted lane (398, 337, 627, 1304, 1538; six files because 398 has two cases)
passes 966 assertions locally. The package checks the shared fixture offline and
requires this targeted lane plus one complete host suite before commit/push.
Full host acceptance remains pending. No new historical case file, schema,
configuration, service action or performance claim is introduced.

Next: review the remaining chaninfo owner/flag read contracts before deciding
whether another domain reader is worthwhile. This increment does not authorize
bulk relocation of permission/presentation code. Keep key disclosure in the
command and retain admission versus display failure-policy differences. Phase B
and broader C/D remain open, including authentication cache contracts and
separate generic-worker final-exit coordination.


## MB1245 — Chaninfo registration reader

Base `dd2a8605a8227a4d479af8953b1374535e5ce8ba` is committed MB1244.
Every tracked source file matches the supplied 2026-11-12 12:20:32 snapshot;
commit.sh is guarded against that snapshot. No missing host totals are inferred.

[Channel::Registration::read_for_info](../Mediabot/Channel/Registration.pm)
owns the exact registration SELECT, prepare, execute and fetch. The USER_CHANNEL,
USER and CHANNEL join, level 500, LIMIT 1, bound channel ID and all raw fields
(including key) remain unchanged. Its found/missing/error result carries the
original row, statement and SQL. It loads independently without bot, transport,
DBI or cache dependencies and introduces no defaults or schema changes.

[Chaninfo](../Mediabot/ChannelCommands.pm) retains channel selection, permissions,
Master-only key/mode/autojoin disclosure, defaults, notices, diagnostics, finish
and audit. Success finishes before presentation; false execute logs and notices
before finish. Thrown prepare/execute/fetch/finish/logger/notice failures retain
identity and ordering. No cleanup improvement is smuggled into the extraction.
Flags and antiflood follow only after successful registration as before.

[The existing fixture](../t/lib/MB1244Chaninfo.pm), still invoked by case 398,
now covers 41 scenarios and 416 assertions. All pass against both the original
command and the extraction; complete traces match. Added cases exercise every
registration statement failure, false finish, throwing diagnostics/notices,
raw metadata and defined empty strings. Ordinary callers cannot receive keys.
The six-file targeted lane passes 1,024 assertions locally. The package checks
cold loading and baseline traces, then requires the targeted lane and one full
host suite before commit/push. Complete host acceptance remains pending.

Next: characterize the remaining chaninfo flags query before deciding whether
its own domain reader is worthwhile. Keep permission and presentation authority
in the command. Broader phases B/C/D remain open, including authentication cache
contracts and separate generic-worker final-exit coordination.


## MB1246 — Chaninfo flags reader

Base `15680ec6700d209572ec3c00c4621c13886c2abc` is committed MB1245. Every tracked
file matches the supplied 2026-11-12 12:34:51 snapshot. commit.sh is guarded
against that snapshot; missing host test reports are not inferred from commits.

[Channel::Flags::read_for_info](../Mediabot/Channel/Flags.pm) owns chaninfo's
exact CHANNEL_SET/CHANSET_LIST SELECT, bound ID, prepare, execute and raw row
collection. It returns rows in database order with the original statement and
SQL; false prepare/execute remains error, while 0E0 and empty rows are successful.
No sorting, deduplication, normalization, caching or permission policy is added.

[Chaninfo](../Mediabot/ChannelCommands.pm) retains nonempty-value filtering,
+flag presentation, case-insensitive AntiFlood substring matching, diagnostics,
finish, notices and final audit. A successful read finishes before the flags
notice; a failed prepare/execute logs without a new finish attempt. Exceptions
retain their identity. Failed registration still prevents flags reads; failed
flags processing prevents downstream flood reads as before. Raw rows are gathered
before formatting; ordinary DBI hash rows preserve the observable command trace.

[The existing fixture](../t/lib/MB1244Chaninfo.pm) now has 50 scenarios and 479
assertions, passing on the old and new command. Complete operation traces match.
Added cases cover prepare/execute/fetch/finish exceptions, false finish, throwing
notice/logger callbacks, empty 0E0 results, undefined/empty flags, duplicates,
zero strings and historical substring matching. The six-file targeted lane
passes 1,087 assertions locally; the full host suite remains required before
commit/push. No new historical case file or runtime configuration is introduced.

Next: checkpoint the completed bounded chaninfo split and inspect its remaining
module dependencies before selecting another phase B/C boundary. Avoid further
fragmentation of presentation code merely to move lines. Keep authentication
cache contracts and generic-worker final-exit coordination as separate open
work; broader phases B/C/D are not declared complete.


## MB1247 — User-resolution contract checkpoint

Base `7326eb8151caf0cdfa2f6a06be2c689f569be8e9` is committed MB1246. All tracked
files match the supplied 2026-11-12 13:04:22 snapshot. This delivery changes only
CHANGELOG and architecture documentation; it does not change authentication.
No absent host test transcript or acceptance total is reconstructed from Git.

### Chaninfo boundary now established

[ChannelCommands::userChannelInfo_ctx](../Mediabot/ChannelCommands.pm) orchestrates
[Registration](../Mediabot/Channel/Registration.pm),
[Flags](../Mediabot/Channel/Flags.pm) and
[FloodRules](../Mediabot/Channel/FloodRules.pm). Those readers do not import
Helpers or command presentation. The command still imports Helpers, DynamicTemplate
and TextBudget for its wider responsibilities; the split does not make the entire
ChannelCommands module independently loadable or remove all bidirectional edges.

Keep context/target selection, Master-only key/mode/autojoin disclosure, defaults,
flag filtering, AntiFlood substring matching, notices, diagnostics, finish and
audit in the command. Preserve different error/cleanup orders between the three
queries. No further decomposition of its short presentation blocks is selected.
The existing [actual-command fixture](../t/lib/MB1244Chaninfo.pm) remains the
regression owner for this bounded split.

### Next bounded step: characterize user resolution before extraction

[Helpers::get_user_from_message](../Mediabot/Helpers.pm) combines hostmask parsing,
a five-second cache, lazy Auth creation, a grouped user/hostmask SELECT, matching,
User construction, level loading, autologin and session synchronization.
[Context::user](../Mediabot/Context.pm) separately memoizes both success and absence
for one Context object. [Auth](../Mediabot/Auth.pm) owns credential verification,
hostmask matching and session invalidation. These are distinct authorities.

The first increment must execute the actual Helpers function with controlled
clock, DB, Auth/User and bot callbacks, not reconstruct its body into a fake
package. Extend [case 194](../t/cases/194_get_user_from_message_no_password_select.t)
or its shared fixture. Retain
[session lifecycle](../t/cases/591_mb372_auth_session_lifecycle.t) and
[nick rekey](../t/cases/596_mb377_auth_nick_session_rekey.t) integration coverage.

Required characterization matrix:

- Missing message, missing prefix, exact fullmask cache keys and case variants;
  the existing cache uses the full prefix, not a nick-only or canonicalized key.
- Positive cache hit below five seconds; expiry at exactly five seconds; no
  Helpers negative cache for an unmatched user. Context absence memoization must
  not be confused with global absence caching.
- Preserve current wall-clock subtraction and timestamp captured before lookup;
  test rollback explicitly before proposing a separate clock-policy change.
- Keep lazy Auth initialization with bot/metrics and reuse of an existing Auth.
  No password/hash column enters the lookup or resulting identity data.
- Exact GROUP_CONCAT ordering, user-id ordering, LEFT JOIN and projection;
  hostmask matching first, Undernet cloak fallback only after a mask miss,
  strictly greater score replacement and first-row tie behavior.
- Snapshot the selected row; preserve prepare/execute/fetch/finish failure order,
  false DBI results and 0E0 truth. Preserve diagnostic and exception identity;
  do not silently add cleanup or turn read failures into cached absence.
- User construction, load_level, pre-auto snapshot, optional maybe_autologin,
  post-auto snapshot, _ensure_logged_in_state, post-ensure snapshot, cache
  publication, matched diagnostic and return snapshot remain ordered. Check
  each callback failure and whether cache publication has already happened.
- clear_user_cache(fullmask) removes both object and timestamp for that key;
  clear_user_cache() clears both maps. Auth logout invalidation and nick rekey
  must still clear the appropriate old aliases without affecting other sessions.

Only after these traces exist should the next implementation select a bounded
SQL boundary. Prefer leaving per-row matching interleaved with fetch unless
characterization justifies changing that order. Retain Helpers entry points and
bot method compatibility; do not move authorization into a generic cache class,
merge Context/Helpers caches, or relocate the full function merely to shrink a file.

MB1247 requires documentation references/symbol checks and guarded patch/commit
checks only. The next runtime increment requires native targeted cases and one
full host suite before commit. Broader phases B/C/D remain open; generic-worker
final-exit coordination remains separate from identity resolution.


## MB1248 — Native user-resolution characterization

Base `ad256b888251b0449d3f30c566e46a5654be261f` is committed MB1247. R1 was stopped
by its base guard before application because it expected MB1246. R2 is rebased
onto MB1247 and preserves the committed checkpoint. Source code and test changes
are identical to R1; no runtime module is modified. The guarded commit.sh still
matches the supplied 2026-11-12 13:33:37 snapshot. No newer snapshot was supplied.

[Case 194](../t/cases/194_get_user_from_message_no_password_select.t) retains its
credential-projection checks and runs [a native probe](../t/lib/MB1248UserResolution.pl)
through [ColdProbeBatch](../t/lib/ColdProbeBatch.pm) with one child and a 30-second
bound. The child loads actual Helpers, Context and Auth; it does not reconstruct
function bodies. Clock, DB and User callbacks are controlled only in the child,
so shared-runner DBI state, symbol tables and time remain untouched.

The 86 assertions cover successful call order, Auth bot/metrics initialization,
no-password SQL projection and ordering, 0E0, five-second expiry, current rollback
behavior, exact fullmask keys, scoped/global clearing, unmatched lookup versus
Context absence caching, score/tie selection, Undernet cloak boundaries, statement
and callback exceptions, false DB results/finish and actual Auth invalidation.
Existing cases 591/596 retain native session lifecycle and nick-rekey coverage.
Three local mutations (TTL boundary, tie selection and timestamp clearing) are
rejected by the probe. The targeted three-file runner passes 80 assertions,
including probe status checks; the child separately passes 86 assertions. These
are different counts, not a claim of 166 runner assertions.

This is a first characterization slice, not completion of the entire MB1247
matrix. Next add callback log/publication failure checks, missing/undefined prefix
cases with rows, optional autologin absence, slow lookup start-time behavior and
selected-row snapshot checks before choosing an extraction. Retain Context positive
memoization and session alias boundaries in that next review. Keep runtime code
unchanged until the remaining characterization justifies a bounded SQL boundary.

The package runs targeted tests and one full host suite before commit/push to
verify the new child probe integrates with the shared runner. Full host acceptance
is pending; schema, configuration, services and production authentication remain
unchanged. Broader phases B/C/D remain open.


## MB1249 — User-cache publication contracts

Base `fb0b53f97a79c40149b26e733a39fb09cd8db06d` is committed MB1248. All tracked files
match the supplied 2026-11-12 13:54:16 snapshot; commit.sh is guarded against it.
No unprovided host acceptance totals are inferred. Production modules are unchanged.

[The existing child probe](../t/lib/MB1248UserResolution.pl) now passes 132
assertions. Added checks cover initial/cache/SQL/absence/matched logger exceptions,
object and timestamp publication, optional autologin absence, undefined/empty
prefixes with candidate rows, clock advancement during lookup, a reused cursor
row, Context positive memoization and real Auth invalidation scopes.

Observed contracts that the extraction must retain:

- Initial/cache-hit logging can throw before lookup or return. A matched diagnostic
  runs after object and timestamp publication: its failure does not undo the cache.
- A slow lookup stores the timestamp captured before SQL and callbacks. It can be
  expired on its next access. No clock-policy improvement is bundled here.
- Copying the winning row prevents a later fetch from replacing its fields.
- An already-resolved Context retains its user after global cache clearing; new
  Contexts can resolve afresh. This is not a process-wide negative/positive cache.
- Known-session invalidation clears that fullmask while preserving another user.
  Missing hostmask clears Helpers maps but still removes only the requested aliases.

The existing targeted lane (194/591/596) passes 80 runner assertions; the isolated
probe separately passes 132 assertions. Mutations removing the winning-row copy
or replacing lookup-start time with completion time are detected. The test still
runs in a bounded fresh interpreter, leaving runner time and DBI state untouched.
The package requires one full host suite before commit to check integration.

Next implementation: isolate only the user/hostmask SELECT preparation and execute
behind a domain-owned cursor-opening function. Keep the exact projection, grouping,
ordering, no-argument execute and original statement identity. Preserve false/error
and 0E0 behavior and leave fetch/matching interleaved in Helpers. Do not eagerly
materialize all users or move cache/session/authorization into the data reader.
Keep Helpers entry points and their call order; update case 194's SQL projection
check to inspect the new owner while retaining native behavior coverage. Compare
full observable traces before/after and run the native plus session/rekey lane,
then one complete host suite. Broader phases B/C/D remain open.


## MB1250 — User candidate cursor owner

Base `41abc50b9a45b5edef62c23663d5c59aa93fab20` is committed MB1249 and matches all
tracked files of the supplied 2026-11-12 14:04:09 snapshot. commit.sh is guarded
against that snapshot. Missing host acceptance totals are not inferred.

[User::Lookup::open_candidates](../Mediabot/User/Lookup.pm) now owns only the exact
user/hostmask SELECT, prepare and no-argument execute. It returns explicit success
and the original statement, including the false-execute statement. It neither
fetches nor finishes, imports no bot/DBI/Auth dependencies, and preserves 0E0 and
exception propagation. Helpers loads it lazily after existing Auth initialization.

[Helpers::get_user_from_message](../Mediabot/Helpers.pm) keeps the interleaved
fetch/matching loop, winning-row snapshot, failure diagnostics, finish and all
User/autologin/session/cache callbacks. SQL bytes, projection, grouping and
ordering are unchanged; no password enters the candidate projection. Context
memoization and Auth invalidation are unaffected.

[Case 194](../t/cases/194_get_user_from_message_no_password_select.t) checks the
SQL projection at its new owner and retains credential separation and actual
resolution coverage. [The child probe](../t/lib/MB1248UserResolution.pl) has an
optional trace output argument for release comparisons; normal test execution
writes no file. All 132 assertions pass before and after, and complete collected
operation/log traces are byte-identical. The targeted 194/591/596 lane passes 82
runner assertions. Cold loading confirms no Helpers/Auth/User/DBI dependency.
The delivery requires one full host suite before commit/push; acceptance is pending.

Next: review the remaining Helpers identity-resolution responsibilities against
these preserved contracts, then choose a single explicit boundary (matching or
cache policy) only if it reduces coupling without hiding authorization. Do not
merge Context/Helpers caching or generalize SQL readers mechanically. Changes to
clock rollback, failure cleanup or diagnostic exceptions require separate behavior
changes and regression cases. Broader phases B/C/D remain open.
