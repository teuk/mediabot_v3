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
