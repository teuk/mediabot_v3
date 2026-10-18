# Mediabot maintenance — 18 October 2026

## Review scope

This round starts from the supplied `3.6dev-20261017_220314` snapshot, after
MB832/MB833. It follows the configuration lifecycle and its IRC administration,
reload and instance-activation callers, and revisits the earlier maintenance
notes alongside event, scheduler and state-persistence code. It is a focused
review of shared persistence, not an assertion that every project line or
external integration has been audited.

The concrete change closes the configuration-save follow-up identified in
`MAINTENANCE_20261017.md`. No additional defect is claimed for the other paths
read in this round.

## Reproduced defects

| Trigger | Previous behavior | New contract |
| --- | --- | --- |
| Serializer writes part of the configuration, then returns false | `Config::Simple::write` truncates the active file first. `Conf::save` returns false, which callers can ignore. | Serialize in a private temporary file and check the result. Failure throws a bounded exception and preserves the original bytes. |
| Process dies during serialization | Active configuration can contain only the prefix already written. | The active file remains the previous complete version until atomic publication. A SIGKILL regression exercises the real process boundary. |
| Two objects load one file and save successive changes | The later stale object silently overwrites the first writer. | A shared lock and revision checks permit one revision to commit; the stale writer must explicitly reload and reapply its intended change. |
| Operator edits a file before or during preparation | A later bot save can erase the operator's changes. | Compare path, inode, owner/group/mode, link count and a SHA-256 content revision before preparation and immediately before publication. Refuse an observed conflict. |
| A scalar contains a literal comma or quotes | Unquoted serialization can turn a scalar into a list or lose text on re-read. | Use the dependency's strict quoting during this save only; preserve scalar/list boundaries, quotes, whitespace and backslashes. |
| An IRC administration save returns false or throws | A false result can still produce a success notice; an exception can escape the handler. | OpenAI set/reset/profile and debug catch both outcomes, issue a private failure notice and log a bounded reason. The live logger changes only after successful persistence. |

The first 67 regression assertions fail 26 checks on the old save path. The
expanded filesystem regression fails 45 of 103 checks on that same source,
including abrupt process death, literal values, caller-owned arrays, metadata
and lock behavior. A separate test exercises real administration handlers and
their current authentication/Owner gates, with false, exception and real file
revision failures. The delivery README records final validation counts.

## Save and reload semantics

- `set` retains its existing immediate in-memory behavior. `save` persists
  that pending state; a failed save does **not** roll back prior `set` calls.
  Retry only after resolving an I/O/lock failure. For a revision conflict,
  reload and explicitly reapply the intended settings.
- Caller-owned list elements are copied before the dependency normalizes them;
  `set` no longer rewrites its caller's array in place.
- `reload` still publishes a complete parsed replacement in memory. It now
  also checks that the file revision remained stable while it was read.
- The existing Config::Simple parser/serializer remain in use. Save locally
  enables its strict quoting, so literal punctuation and whitespace round-trip
  without changing global dependency settings. Physical CR/LF/NUL in keys or
  values are refused before publication; INI continuation is not introduced.
  Existing values already parsed as lists are retained as lists; no heuristic
  attempts to reconstruct a previously unquoted text value.
- Memory-only configuration objects retain their no-op `save` behavior.
- Errors identify a bounded failure stage, never dependency exception text or
  configuration values. A failed save cannot be reported as successful by code
  that reaches its success notice only after `save` returns.
- Owner-only administration handles a failed save without allowing an
  exception to escape the IRC command. Its notice explicitly states that
  pending values remain in memory; it does not claim a failed change was rolled
  back or permanently stored. The server log uses `CONFIG_SAVE` reason codes.

## Filesystem and concurrency boundaries

The temporary file is created with mode 0600 in the resolved configuration's
directory. Serialization completes before owner, group and original mode are
applied. File sync precedes rename. The directory must permit replacement, and
the caller must be able to preserve the existing owner/group. The contract
preserves POSIX owner/group/mode; it does not clone extended ACLs or filesystem
attributes. Configurations relying on those need a separate deployment review.

A stable symbolic configuration path remains a symbolic link; publication
replaces its resolved target. Retargeting that path requires an explicit reload.
Multiple hardlinks are refused rather than silently splitting a shared file.

`<resolved-config>.lock` is persistent, private and opened without following
symbolic links. Multiply-linked or non-regular lock files are refused before
metadata changes. The lock is nonblocking so a competing writer cannot stall
the IRC event loop. Root-side saves preserve the configuration owner's ability
to use the lock later.

Do not delete the lock while writers can run. Cooperating writers use this
shared lock; unrelated editors, installers and older versions do not acquire
it. Observed external edits are rejected, but this is not a compare-and-swap
primitive against an uncooperative writer in the final check/rename interval.
Keep the established practice of stopping the instance before operator edits.

A process killed before publication can leave a private `.mediabot-conf-*`
temporary file. No startup code blindly deletes such files, because another
writer might still own one. Inspect them only after stopping writers. The lock
and temporary names are ignored by Git. Atomic rename protects complete-file
visibility; it is not a guarantee for every storage or power-failure scenario.

## Deployment

Source installation changes no private configuration or running process.
Restart `mediabot@dev.service` after source validation to load the new class.
Other IRC instances receive the committed source through the normal update
workflow. There is no database, dashboard, publisher or mbweb deployment.

Filesystem regressions use temporary dummy configurations. Live acceptance
does not require writing real credentials or changing a production setting.

## MB836 follow-up — Runtime ownership

This second maintenance pass starts from the supplied
`3.6dev-20261017_232115` snapshot, including MB834 and MB835. It follows delayed
results, scheduler ownership and PID-file lifetime, alongside the previously
reviewed persistence/export paths. The three defects below were reproduced on
that unchanged source; other paths read are not claimed defect-free.

| Trigger | Reproduced behavior | Correction |
| --- | --- | --- |
| A private AI room expires, then the same scope is recreated before an old completion arrives | The new room restarts at epoch 1. The old epoch-1 ticket becomes current again, even for the same actor/speaker, and its expired question/answer can enter the new history. | Match both epoch and a fresh 128-bit room incarnation. Rejected tickets cannot write history. |
| A periodic task is removed while a caller still holds its timer/callback | The callback retains the task and scheduler; even a retained tick invoked after stop/removal can still execute and update counters. Repeated add/remove cycles retain those object graphs. | Hold weak task/scheduler references and validate current registry identity and started state before accounting or dispatch. |
| A locked PID path is replaced before the old owner releases its open descriptor | Reading the old descriptor still proves its own PID, so release unlinks the new owner's path. The replacement's lock is then detached from the public PID path. | Compare the acquired directory entry and the path's target with the owned descriptor. Preserve a replacement, close only the old handle and report the conflict. |

### Private memory compatibility

The JSON state remains version 1. Existing rooms acquire `incarnation` on their
next successful `begin_turn`; their turns, speaker labels, names, epoch and
daily usage are retained. A ticket includes the room's incarnation; both
`current` and `commit_turn` check it with the epoch. Personal erasure still
advances the epoch, and a legitimate nick rename does not change the room
incarnation. An expired/recreated room receives a different incarnation even
if its actor, speaker label and epoch coincide with the former room.

Incarnations use 16 bytes from the operating system's `/dev/urandom`, available
on the supported Debian/Linux hosts. Failure to obtain a complete value fails
the begin operation without publishing partial memory. This is a room
lifecycle identifier, not a provider key or an authorization credential.
Malformed stored incarnations are rejected while preserving the file for
recovery. Tickets missing a valid incarnation are rejected without writing.
No operator migration or deletion of the memory file is required.

### Scheduler ownership

The real IO::Async loop still owns active periodic timers; the registry owns
their task records. Callback closures no longer create an additional strong
task/timer/scheduler cycle. Explicit start/stop/remove/re-add operations remain
the lifecycle controls. Retained tick events for stopped, removed or replaced
tasks neither run callbacks nor inflate task statistics. Running callbacks
still pass through the existing duration/error helper, and calendar generation
checks are unchanged. Tests use real periodic timers and a real loop; retained
events are explicitly invoked to exercise delayed-callback safety.

### PID-file boundaries

Acquisition checks that its directory entry and target still identify the
opened descriptor before reporting success. Mode changes use that descriptor,
so an observed replacement does not get chmodded through a stale pathname.
Release preserves replacement regular files and symbolic entries, including
an alias newly created to the same target. Stable symbolic PID aliases retain
their previous behavior: release removes the owned alias, not its target.
Normal release, an already missing path and repeated release remain supported.

These checks detect observed replacement; they are not a filesystem
compare-and-unlink primitive against an unrelated writer racing the final
check/unlink interval. Do not edit/remove live PID files to start a second
instance. The existing rule remains: stop the exact service before operator
changes to its runtime files. A conflict produces a bounded diagnostic and
releases the old descriptor without claiming that the replacement was removed.

### Validation and rollout

The delivery README records regression, targeted, fast and complete-suite
results, including local limitations. Source installation preserves private
configuration, state files, databases, index and services. No dashboard or
publisher upgrade is required. After the normal commit/update workflow, live
acceptance remains on **#i/o on Epiknet through nbot**, the instance already
configured for collective AI. A successful private follow-up after the update
checks normal continuity without changing live settings; restart/reload is
what loads the new in-memory classes.
