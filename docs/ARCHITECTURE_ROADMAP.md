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
| D | Make timer/worker/resource ownership and shutdown order explicit. Inventory existing resources first; migrate one family with idempotent cleanup. Distinguish shutdown, IRC reconnect and rehash. | Connection output and nicklist retirement delivered (MB1212–1214, MB1218); achievement ownership/collection (MB1219–1225) and archive collection (MB1226, `473a0b1b`) committed. Phase D remains open; current priorities are in the MB1227 checkpoint below. |
| E | Reduce PluginManager responsibilities. Extract runtime-state persistence and diagnostics separately while keeping lifecycle/security authority explicit. | MB1215 persistence (`8467555`) and MB1216 portfolio diagnostics (`a9d10caa`) committed/pushed; bounded phase E pilot delivered. |
| Throughout | Replace source-body reconstruction with actual component tests and injected clock/transport/storage dependencies; retain native integration tests. | MB1208 (412, 1110), MB1209 (337, 627, 1538). |

Current continuation point: MB1228 implements the Scheduler removal prerequisite
below; plugin-job ownership remains next. Overall scope: [MB1227 checkpoint](#mb1227--phase-d-checkpoint-and-plugin-job-ownership).
Earlier “Next” paragraphs record decisions at their original increment; they do
not override this checkpoint.

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
