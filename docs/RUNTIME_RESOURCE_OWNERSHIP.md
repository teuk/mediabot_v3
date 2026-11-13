# Runtime resource ownership — phase D inventory

Current continuation checkpoint: MB1254, prepared against committed MB1253
`50e7632b02c38124a1426b2bff16e068ab3c2638`.
Generic-worker physical ownership and bounded final collection are implemented.
The remaining chapter gate is installed-host validation and commit/push, not a
new extraction. See [the closure record](ARCHITECTURE_ROADMAP.md#mb1254--final-worker-collection-and-chapter-closure).
Detailed missing host reports are not reconstructed from commits.
This is a bounded inventory, not a universal cleanup API or a claim that all
plugins, HTTP requests and timers have been audited.

## Three different lifecycle boundaries

| Boundary | Current authority | What it actually does |
| --- | --- | --- |
| IRC reconnect | [mediabot.pl](../mediabot.pl), `reconnect`; [Mediabot.pm](../Mediabot/Mediabot.pm), `restart_irc` and `setIrc` | Reuses the loop so Partyline survives; removes the old IRC object, rebuilds nicklist/main timers and replaces the IRC object. `setIrc` invalidates output registries only when transport identity changes. |
| Rehash | [Mediabot.pm](../Mediabot/Mediabot.pm), `rehash_runtime_state` | Reads config, reloads logging and rebuilds channels/nicklist timers. This is not shutdown or a blanket cancellation of workers/output. |
| Final process exit | [Mediabot.pm](../Mediabot/Mediabot.pm), `clean_and_exit` | Revokes Wit authorization, attempts QUIT, stops the archive worker, attempts bounded collection of all tracked achievement children (including detached ones), saves achievements/Hailo, disconnects DB, releases PID ownership and closes/flushes logging before exit. |

Do not replace these with one generic stop-all operation. Reconnect must retain
Partyline and process ownership; rehash must not silently discard unrelated work.
`clean_and_exit` has a process-wide reentrance guard and exits; it is not a reusable
idempotent cleanup service. MB1254 explicitly retires generic AsyncWorker work for the bot loop before final
saves and teardown. It does not iterate all scheduler tasks or output notifiers;
those exclusions are not proof that every excluded resource leaks.

## Ownership map

| Family and source | Resource owner / identity | Completion or retirement today | Remaining question |
| --- | --- | --- | --- |
| [IRC countdown](../Mediabot/IRC/Timer.pm), `countdown` | One notifier; weak timer reference in its expiry callback; strong setup owner | Stops/removes before user callback; completed/failed-setup callbacks become inert; preserves original exceptions | MB1212 adds explicit `cancel_countdown` revocation; stop/remove alone still do not revoke callbacks. |
| [Paced NOTICE](../Mediabot/IRC/PacedOutput.pm), `queueBotNotices` | `_notice_queue_timers` array identity, plus each countdown | Expiry releases its slot; MB1212 setIrc detaches the registry, publishes transport, then explicitly cancels its timers | Removal exceptions leave inert notifiers in the broken loop and produce a diagnostic; cancellation is not a physical cleanup retry API. |
| [Paced PRIVMSG](../Mediabot/IRC/PacedOutput.pm), `_queue_irc_chunks` | `_external_ai_output_queues` target state; `timer`, `current`, `batches`; guarded pump | MB1213 detaches all old targets, clears batches/guards/pump ownership and cancels their countdowns; arm identity preserves inline successors | MB1213 accepted; final-exit coordination remains separate. |
| [Deferred AntiFlood](../Mediabot/IRC/DeferredOutput.pm), `_arm_flood_drain` | `_flood_outq` target queue; owned countdown handle and arm identity; weak expected queue in callback | MB1214 detaches/clears old queues before cancelling notifiers; expiry releases handle before normal drain/retry | Committed as `b321e17`; reconnect retirement does not change final-exit policy. |
| [AsyncWorker](../Mediabot/AsyncWorker.pm), `cancel`, `_cleanup`, `_complete` | Worker owner PID, task ID, process/stream, timeout/kill/force timers | Cancel initiates TERM/KILL/backstop; cleanup deletes timer/stream/FD slots; finalized gate allows completion once; active_workers excludes finalized entries | MB1254 separates CHILDREN from active observation and adds shutdown_loop: revoke callbacks, detach notifiers, bounded TERM/KILL collection; unconfirmed children remain owned. Ordinary cancel is still asynchronous. |
| [Scheduler](../Mediabot/Scheduler.pm), `stop`, `remove`, `registration_id` | Named task plus exact registration ID/generation | Calendar stop removes notifier; ordinary periodic stop stops it; generation changes invalidate old execution; remove has its own semantics | MB1228 rechecks exact task identity after stop/remove callbacks so outer cleanup cannot erase a successor. Stop failure still remains a failure; MB1230 now checks plugin-side exact ownership. |
| [Plugin jobs](../Mediabot/PluginManager.pm), `_stop_v3_jobs`, `_remove_v3_jobs` | Plugin entry's `mounted_jobs` stores name/clock plus Scheduler identity and registration ID (MB1230) | MB1230 checks exact ownership before start/stop/remove and rollback; MB1229 retains failed removal records on a disabled entry and reports incomplete unload | MB1230 implements exact identity and rollback; committed as `9508ecbf`, without a host test total recorded here. Unknown ownership is refused, not inferred from a name. Lifecycle/capability authority stays in PluginManager. |
| [Partyline watch](../Mediabot/Partyline/ShellWatch.pm), `_dispose`, `_remove_owned` | Exact session/stream/state, owner PID and task ID; weak owner references | Marks done, drops renderer, removes only its own scheduler registration; reports incomplete removal | Useful existing model for revoke-first cleanup; preserve session authorization rather than copying it into a generic timer helper. |
| [Nicklist timers](../Mediabot/Channel/NicklistTimers.pm), Mediabot setup/stop delegates | Public `channel_nicklist_timers` map plus private weak-key callback metadata and setup generation | MB1218 detaches/revokes before independent remove/stop; late setup cannot overwrite successors; failures return 0 and log incomplete cleanup | Committed as `7f1529b3`; no detailed host report supplied. Failed physical cleanup is not retried by repeated retirement; final shutdown remains separate. |
| [DB timers](../Mediabot/DBCommands.pm), `_stop_all_runtime_db_timers`, `onStartTimers` | `hTimers` map, detached before cleanup | Stops and removes each old timer in separate eval blocks when rebuilding | MB1238 R2 and MB1239 guards committed; exact identity is rechecked after tick logging for reload and addtimer callbacks. Native case 403 covers these bounded cases; no general shutdown guarantee follows. |
| [Achievement worker](../Mediabot/Achievements.pm), `shutdown_worker` | Active `_worker_process` plus physical `_worker_children` registry and `_shutting_down` gate | MB1219–1225 revoke logical delivery, retain accepted detached children, clean notifier setup failures and attempt bounded shared-budget TERM/KILL collection without running the loop | Unconfirmed records remain owned and diagnosed; watcher completion retires exact records. This is family-specific, not generic AsyncWorker shutdown. |
| Archive worker in [Mediabot.pm](../Mediabot/Mediabot.pm), `clean_and_exit` | `_channel_log_archive_pid` | MB1226: checked TERM/KILL with bounded WNOHANG polling before DB teardown; watcher refusal uses the same routine with immediate KILL | Retain unconfirmed PID ownership and diagnose uncertainty. No blocking waitpid or loop iteration; ordinary reconnect is unchanged. |

The inspected reconnect resets `_af`, `_af_params`, `_chan_flood`, `_nick_flood`,
`_nick_mute`, `_cmd_cooldown` and the netsplit counter. This is separate from the
three output registries retired by `setIrc`; neither list is a universal resource
registry. Do not infer that changing an IRC reference cleans all bot state.

## First migration selected: paced NOTICE retirement

Choose NOTICE before the coupled PRIVMSG pump or child processes: there is an
explicit notifier array and existing connection-identity tests. The goal is
prompt retirement of old NOTICE payload/notifiers on transport replacement,
while preserving wire behavior, pacing, truncation and fallback. Implemented in
MB1212, accepted on host; not part of the docs-only MB1211 commit.

Migration contract (MB1212):

1. Capture and revoke the old registry identity before invoking stop/remove or
   user-visible callbacks. Publish no old registry back into the bot.
2. Revoke each owned callback and release its captured output, including when an
   external reference retains the callback. Merely stopping a timer is insufficient.
3. Attempt stop and removal independently so one failure cannot suppress the
   other. Preserve exception policy and expose incomplete physical cleanup.
4. Make repeat cancellation harmless; never cancel a newer registry created by
   reentrant cleanup. Track exact notifier ownership, not target nickname alone.
5. Preserve countdown's current public return contract unless every affected
   caller is migrated and tested. Add an explicit cancellation interface rather
   than treating existing stop as if it already revokes callbacks.
6. Wire the first increment only to changed-transport retirement. Rehash retains
   notices; setting the same IRC object retains its registry. Final shutdown
   ordering needs a separate integration review before reusing this operation.

Acceptance matrix for that runtime increment:

| Trigger | Required observable result |
| --- | --- |
| Same IRC object / rehash | Existing valid NOTICE work remains scheduled. |
| Replacement IRC / undef transport | No old private payload reaches the new transport; owned notifiers removed when the loop cooperates. |
| Retained stale callback | Inert after retirement and holds no old output payload. |
| Repeated / reentrant cancellation | No duplicate side effects; successor registry and timers remain untouched. |
| Stop throws / remove throws | Other cleanup action still attempted; no old send; incomplete physical cleanup is distinguishable. |
| Inline expiry during add/start | No double send, double cleanup or restart of completed work. |
| Setup failure / transport exception | Existing fallback and no-replay behavior preserved. |

Extend existing cases, not one new file per change:

- [1305 paced output](../t/cases/1305_mb880_irc_paced_output.t): registry replacement and NOTICE scheduling.
- [1309 timer contracts](../t/cases/1309_mb882_irc_timer_contracts.t): callback lifetime and setup failure.
- [1310 queue recovery](../t/cases/1310_mb882_irc_queue_recovery.t): failure recovery and stale callbacks.
- [1311 native lifecycle](../t/cases/1311_mb882_irc_native_timer_lifecycle.t): real IO::Async cleanup.
- [1520 inline add](../t/cases/1520_mb1146_timer_inline_add.t): synchronous expiry edge cases.

Then run native integration and the full suite once before the runtime commit.
MB1211 itself changes documentation only: validate its paths/symbol references,
exact source base and patch scope instead of rerunning the six-minute suite.

## Explicitly deferred

Radio/YouTube behavior, metrics HTTP listener, RSS/news timers, DCC sockets,
provider-specific requests, and every individual plugin's resources are outside
this bounded audit. Audit their owner and lifecycle before any later universal
shutdown proposal. Phase E file persistence and portfolio diagnostics pilots
are delivered; lifecycle/security authority remains in PluginManager.

### MB1222: timeout escalation setup

The achievement timeout callback catches failures installing its KILL and forced
completion countdowns. It immediately signals an unfinished child with KILL and
uses the existing forced timeout completion to retire partial notifiers. The
accepted process watcher retains reaping ownership; late callbacks cannot deliver
again or clear successor work. Normal timeout delays and final shutdown remain
unchanged. This is asynchronous cleanup, not a guarantee that the child has exited
at the instant the completion callback runs.

### MB1223: reaped achievement processes

The process watcher retires only its own process record immediately upon observed
child exit. Pipe EOF may still be pending; result delivery and logical in-flight
ownership remain separate. Shutdown no longer sees that reaped PID as a signal
target, inline exit is not republished, and old EOF cleanup cannot erase a newer
process record. MB1224 below supersedes the former TERM-only final shutdown.

### MB1224: active achievement child at final exit

The active process record supplies a one-shot callback that revokes native result
and timer callbacks and detaches resources. Final shutdown then checks child
ownership with WNOHANG before TERM and KILL, with at most twenty 5ms polls per
phase plus a final nonblocking observation. No event-loop callbacks are driven.
Confirmed collection allows unwatch_process; unconfirmed collection is logged
and returns false, retaining the watcher if the loop ever resumes. Logical
revocation and final save remain unchanged. This does not drain detached children
whose earlier forced completion already removed their active process record.

### MB1225: achievement children after forced completion

_worker_children holds records for accepted watchers until observed exit, while
_worker_process remains only the active result slot. Forced completion no longer
removes physical ownership. Final shutdown polls the complete owned batch with
shared TERM/KILL sleep budgets, unregisters confirmed children and retains
unconfirmed records for watcher completion or retry. Empty registries disappear.
This supersedes MB1224's active-only scope limitation; rejected watcher setup
still uses its existing bounded immediate collection path. No loop is driven.

### MB1226: archive collection boundary

_stop_channel_log_archive_worker owns final-exit and rejected-watcher collection.
Only confirmed waitpid/ECHILD clears matching process state. Wait errors do not
claim success; EINTR remains within the polling budget. Before either signal a
nonblocking wait verifies child ownership. Final shutdown allows ten 50ms polls
per TERM/KILL phase; setup failure has only the KILL phase. Unconfirmed children
remain tracked. Late watcher callbacks for a different/cleared PID are inert.

## MB1228 — Scheduler removal prerequisite

At base `f92fb0903bf694030e243aaff161eb3e8c5e1793`, reentrant stop logging and
loop removal could replace a task before the outer removal deleted its name.
Exact-reference checks now preserve that successor. Four periodic/calendar
scenarios reproduce the defect and cover stale callbacks and later cleanup.
This is not a plugin-job migration or generic worker shutdown change; current
manager-side ownership and incomplete-removal findings remain open.

## MB1229 — retained plugin cleanup ownership

Failed API v3 unload keeps the disabled entry and unresolved mounted_jobs.
False returns, exceptions and missing Scheduler are explicit failures; cleanup
continues for other jobs. Retry unload completes only the outstanding work,
including native tasks already removed separately. Persistent unload does not
write success on failure, and activation/replacement cannot discard this pending
owner. Exact task registration identity and mount rollback are still pending.

## MB1230 — exact plugin-job registration authority

Mounted jobs now retain scheduler identity and exact callback registration ID.
Lifecycle operations and mount/start rollback preserve same-name successors;
old callbacks, later channels and output guards reject superseded registrations.
Partial add ownership is captured before cleanup. Failed removal still retains
its disabled owner for retry as in MB1229. Unknown identity fails closed; names
alone cannot recover pre-change in-memory ownership. This is a bounded plugin
adapter change using the existing native Scheduler registration API.


## User-resolution cache ownership checkpoint (MB1247)

[Helpers](../Mediabot/Helpers.pm) stores positive user objects and timestamps in
`_user_cache` / `_user_cache_ts`, keyed by exact fullmask. Its five-second freshness
check uses wall-clock subtraction; it does not purge all stale entries or cache
unmatched users. `clear_user_cache` removes one key from both maps or replaces
both maps. No monotonic clock, eviction bound or cache-policy change is delivered.

[Context::user](../Mediabot/Context.pm) has a separate `_user_fetched` marker and
memoizes absence for that Context object. [Auth::_invalidate_bot_session](../Mediabot/Auth.pm)
attempts cache clearing for a known session hostmask (or all keys when absent),
then removes nickname-keyed aliases. These scopes must remain distinct.
The MB1248–1251 native characterization observes callback/cache publication order;
this inventory does not certify the complete authentication lifecycle.

MB1249 additionally characterizes publication before the matched-user diagnostic,
lookup-start timestamp ownership, winning-row snapshots and Context positive
memoization after a Helpers cache clear. These tests preserve existing behavior;
they introduce neither a universal invalidation API nor a new cache lifetime.


## MB1252 — Remaining final-exit decision

The inspected clean_and_exit handles archive and achievement children explicitly,
but does not enumerate generic AsyncWorker instances. active_workers is an
observation API scoped to a loop and owner PID; it discards finalized entries.
_complete deletes the active registration before calling on_done. cancel requests
asynchronous termination. None of these facts alone proves that a child survives
exit, or that every accepted child has been collected.

Before wiring shutdown, characterize active, stopping and finalized-but-unreaped
children in disposable native processes. Record ownership through completion,
TERM/KILL, wait errors, retained callbacks and parent exit. Inspect caller result
contracts before suppressing callbacks. If collection is needed, require a shared
bounded budget, exact child ownership, no arbitrary event-loop iteration during
teardown, and truthful incomplete-cleanup diagnostics. Preserve DB/log availability
for required final saves and keep reconnect/rehash unchanged.

The next delivery must resolve this decision or explicitly document why a larger
follow-up is required. Do not expand the inventory to every plugin or listener as
a prerequisite. The final chapter checkpoint records this disposition and host
acceptance; it does not certify a universal shutdown API.


## MB1253 — Generic-worker decision resolved, implementation pending

The isolated native exit probe demonstrates that cancel plus immediate parent
exit does not collect a TERM-resistant child. With deliberately delayed process
notification, logical finalization removes active-task visibility before physical
collection is confirmed. The observer owns cleanup in these probes; they neither
invoke the full bot exit path nor certify deployment service-manager behavior.
Source inspection confirms that clean_and_exit lacks a generic-worker shutdown
operation. The required next increment is separate physical ownership, callback
revocation and bounded batch collection at final exit. No new resource family is
added to this chapter. Archive/achievement behavior and ordinary reconnect remain
outside that correction except for preserving their established ordering.


## MB1254 — Final-exit implementation

CHILDREN strongly owns each forked worker until its watcher observes exit or a
checked wait confirms collection/absence. ACTIVE remains weak and logical.
shutdown_loop combines physical and logical owners, refuses new starts using weak
loop keys plus owner PID, and revokes the entire batch before invoking cleanup.
All waitpid calls are nonblocking; the two polling phases share sleep budgets
across children. No event-loop iteration or consumer completion callback runs.

Confirmed collection releases physical ownership and attempts unwatch_process;
errors are distinguished from unconfirmed children. Repeated collection can retry
uncertain child ownership but does not retry detached notifier removal. Retained
callbacks remain inert. Main final exit diagnoses failure and continues saves,
DB/PID/log teardown. Reconnect, rehash and ordinary result delivery are unchanged.

The existing case 1251 launches a fresh native probe, including the actual main
exit function with unrelated imports stubbed. Host native/targeted/full validation
is still required. Successful MB1254 host validation and commit/push closes the
bounded chapter; the wider exclusions are retained, not silently certified.


## MB1269 — Connection-owned control/output admission

`Mediabot::IRC::Transport` owns pending writes and one active native write.
Complete PONGs may overtake only pending whole frames. Ordinary output remains
FIFO; raw partial/opaque writes impose a conservative priority barrier. The loop
owns a weakly-captured later-turn pump, which becomes inert after retirement.
`close_now` / `retire_output` detach pending payloads before failing their Futures
and closing native output; `close_when_empty` drains accepted work. `setIrc`
publishes its successor before invoking retirement on the old capable transport.
No new timers, global connection registry, database data or live configuration
are introduced. Native Net::Async::IRC timer reference cycles are outside this
increment; this is not a claim that the entire underlying client becomes weak.
Aggregate queue caps and whole-process shutdown policy remain explicit follow-ups.
