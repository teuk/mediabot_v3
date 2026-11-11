# Runtime resource ownership — phase D inventory

Reviewed at MB1210, commit `97ced23eb5989dade4f3711526f2a7c5bcb31776`.
MB1211 was a documentation-only checkpoint. MB1212 implements the NOTICE pilot
below (accepted as `62f83c0`, 39,423 assertions). MB1213 extends retirement to
paced PRIVMSG (accepted as `52e250e`, 39,462 assertions). MB1214 adds AntiFlood
drain ownership/retirement (committed as `b321e17`; detailed host report not
supplied). MB1217 rechecks the nicklist cleanup gap at `a9d10caa` and selects it
as the next bounded runtime increment. MB1218 is committed as `7f1529b3`;
detailed host results were not supplied. MB1219 gates late achievement results. No universal cleanup API is claimed.
This is a bounded inventory of the core lifecycle and first migration candidates,
not a claim that every plugin, HTTP request or timer has been audited.

## Three different lifecycle boundaries

| Boundary | Current authority | What it actually does |
| --- | --- | --- |
| IRC reconnect | [mediabot.pl](../mediabot.pl), `reconnect`; [Mediabot.pm](../Mediabot/Mediabot.pm), `restart_irc` and `setIrc` | Reuses the loop so Partyline survives; removes the old IRC object, rebuilds nicklist/main timers and replaces the IRC object. `setIrc` invalidates output registries only when transport identity changes. |
| Rehash | [Mediabot.pm](../Mediabot/Mediabot.pm), `rehash_runtime_state` | Reads config, reloads logging and rebuilds channels/nicklist timers. This is not shutdown or a blanket cancellation of workers/output. |
| Final process exit | [Mediabot.pm](../Mediabot/Mediabot.pm), `clean_and_exit` | Revokes Wit authorization, attempts QUIT, stops the archive worker, signals the achievement worker, saves achievements/Hailo, disconnects DB, releases PID ownership and closes/flushes logging before exit. |

Do not replace these with one generic stop-all operation. Reconnect must retain
Partyline and process ownership; rehash must not silently discard unrelated work.
`clean_and_exit` has a process-wide reentrance guard and exits; it is not a reusable
idempotent cleanup service. The inspected function does not explicitly iterate
all AsyncWorker registrations, scheduler tasks or output notifiers. That is an
integration question for a later migration, not proof that every resource leaks.

## Ownership map

| Family and source | Resource owner / identity | Completion or retirement today | Remaining question |
| --- | --- | --- | --- |
| [IRC countdown](../Mediabot/IRC/Timer.pm), `countdown` | One notifier; weak timer reference in its expiry callback; strong setup owner | Stops/removes before user callback; completed/failed-setup callbacks become inert; preserves original exceptions | MB1212 adds explicit `cancel_countdown` revocation; stop/remove alone still do not revoke callbacks. |
| [Paced NOTICE](../Mediabot/IRC/PacedOutput.pm), `queueBotNotices` | `_notice_queue_timers` array identity, plus each countdown | Expiry releases its slot; MB1212 setIrc detaches the registry, publishes transport, then explicitly cancels its timers | Removal exceptions leave inert notifiers in the broken loop and produce a diagnostic; cancellation is not a physical cleanup retry API. |
| [Paced PRIVMSG](../Mediabot/IRC/PacedOutput.pm), `_queue_irc_chunks` | `_external_ai_output_queues` target state; `timer`, `current`, `batches`; guarded pump | MB1213 detaches all old targets, clears batches/guards/pump ownership and cancels their countdowns; arm identity preserves inline successors | MB1213 accepted; final-exit coordination remains separate. |
| [Deferred AntiFlood](../Mediabot/IRC/DeferredOutput.pm), `_arm_flood_drain` | `_flood_outq` target queue; owned countdown handle and arm identity; weak expected queue in callback | MB1214 detaches/clears old queues before cancelling notifiers; expiry releases handle before normal drain/retry | Committed as `b321e17`; reconnect retirement does not change final-exit policy. |
| [AsyncWorker](../Mediabot/AsyncWorker.pm), `cancel`, `_cleanup`, `_complete` | Worker owner PID, task ID, process/stream, timeout/kill/force timers | Cancel initiates TERM/KILL/backstop; cleanup deletes timer/stream/FD slots; finalized gate allows completion once | Cancellation request is not synchronous child completion. Consumers must retain result/reaping semantics during shutdown. |
| [Scheduler](../Mediabot/Scheduler.pm), `stop`, `remove`, `registration_id` | Named task plus exact registration ID/generation | Calendar stop removes notifier; ordinary periodic stop stops it; generation changes invalidate old execution; remove has its own semantics | Stop and remove are not interchangeable. Stop failure must not be reported as successful retirement. |
| [Plugin jobs](../Mediabot/PluginManager.pm), `_stop_v3_jobs`, `_remove_v3_jobs` | Plugin entry's `mounted_jobs`, mediated by Scheduler | Stops in reverse order and reports failures; removal is separate | Keep plugin lifecycle/capability authority in PluginManager; never remove a replacement registration by name alone. |
| [Partyline watch](../Mediabot/Partyline/ShellWatch.pm), `_dispose`, `_remove_owned` | Exact session/stream/state, owner PID and task ID; weak owner references | Marks done, drops renderer, removes only its own scheduler registration; reports incomplete removal | Useful existing model for revoke-first cleanup; preserve session authorization rather than copying it into a generic timer helper. |
| [Nicklist timers](../Mediabot/Channel/NicklistTimers.pm), Mediabot setup/stop delegates | Public `channel_nicklist_timers` map plus private weak-key callback metadata and setup generation | MB1218 detaches/revokes before independent remove/stop; late setup cannot overwrite successors; failures return 0 and log incomplete cleanup | Committed as `7f1529b3`; no detailed host report supplied. Failed physical cleanup is not retried by repeated retirement; final shutdown remains separate. |
| [DB timers](../Mediabot/DBCommands.pm), `_stop_all_runtime_db_timers`, `onStartTimers` | `hTimers` map, detached before cleanup | Stops and removes each old timer in separate eval blocks when rebuilding | Keep DB-command scheduling and reconnect publication behavior covered; do not merge with Scheduler solely because both use timers. |
| [Achievement worker](../Mediabot/Achievements.pm), `shutdown_worker` | `_worker_process` PID and `_shutting_down` flag | MB1219 revokes logical parent delivery and resets its gauge, then existing TERM/child cleanup policy applies; final save follows in clean_and_exit | Late success/failure cannot mutate parent state. MB1220 bounds reaping after rejected watcher installation; MB1221 cleans notifier setup failures while the accepted watcher retains reaping. Final-exit TERM is still not confirmed exit. |
| Archive worker in [Mediabot.pm](../Mediabot/Mediabot.pm), `clean_and_exit` | `_channel_log_archive_pid` | TERM, bounded WNOHANG polling, then KILL/waitpid before DB teardown | Preserve this ordering; do not generalize its blocking final-exit behavior to ordinary reconnect. |

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
