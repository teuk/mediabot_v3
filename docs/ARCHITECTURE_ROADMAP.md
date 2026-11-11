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
| C | Separate domain data access from commands and IRC transport. Pilot channel output rules, retaining cache freshness, last-known-good data and failure policy. | MB1210 R2 reader accepted (`97ced23`); operator UPDATE committed in MB1232 (`cdbdbee6`). MB1233 display read committed (`7b478567`). The antifloodset pilot is implemented; broader phase C remains open. |
| D | Make timer/worker/resource ownership and shutdown order explicit. Inventory existing resources first; migrate one family with idempotent cleanup. Distinguish shutdown, IRC reconnect and rehash. | Connection output and nicklist retirement delivered (MB1212–1214, MB1218); achievement ownership/collection (MB1219–1225) and archive collection (MB1226, `473a0b1b`) committed. Plugin-job recovery/identity delivered (MB1228–1230). Phase D remains open; see the MB1231 checkpoint below. |
| E | Reduce PluginManager responsibilities. Extract runtime-state persistence and diagnostics separately while keeping lifecycle/security authority explicit. | MB1215 persistence (`8467555`) and MB1216 portfolio diagnostics (`a9d10caa`) committed/pushed; bounded phase E pilot delivered. |
| Throughout | Replace source-body reconstruction with actual component tests and injected clock/transport/storage dependencies; retain native integration tests. | MB1208 (412, 1110), MB1209 (337, 627, 1538), MB1232–1233 native antifloodset case 398. |

Current continuation point: MB1236 implements badword command data access after
MB1235 (`043310dd`, committed). Host acceptance remains pending. Read and write SQL
now have a channel-domain owner; cache, permissions and presentation remain with
their existing callers. Checkpoint this pilot before selecting another family.
Earlier “Next” paragraphs are historical decisions, not current instructions.

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
