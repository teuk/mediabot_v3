# MB1063 — PID ownership after fork

## Defect and reproduction

ProcessLock retains an advisory lock and the PID directory-entry identity.
After fork, the child inherits the object, the configured PID and the open
file description. Its release previously passed the parent's stored-PID and
inode checks and unlinked the live parent's PID path. A second process could
then create and lock a different file while the parent still held the old one.
Acquire also returned success for the inherited handle. An unacquired object
constructed before fork could write the parent's PID from the child.

The native bot's acquirePidFile fast return bypassed any lock-level check on
an existing object. Child cleanup and acquisition are reproduced with real
forks and the native bot method, without an IRC server or database.

## Implementation

Record the actual creating process separately from the configurable PID
payload. Only that process may acquire using the object. An inherited acquire
detaches the child's handle and returns an explicit ownership error. Inherited
release closes only the child's descriptor, with no PID read, unlink or LOCK_UN.
An explicit unlock would affect the parent's shared open file description.

The bot always delegates existing-lock acquisition to ProcessLock. Acquiring
twice in the owner remains idempotent. A child needing its own lock must create
its own ProcessLock object. Parent replacement checks, stable symbolic PID
aliases, stale/live legacy PID handling and normal release remain unchanged.

## Validation and delivery

Extend the existing PID ownership regression with twelve assertions covering
native child cleanup, path bytes/inode preservation, a rejected contender,
native bot reacquisition, a pre-fork unacquired object and a fresh child-owned
object. Reuse the existing file rather than adding another suite startup.

The received 17:26:51 snapshot ends at MB1061. The delivery carries the previously
qualified MB1062 responder patch as a separate continuation, recognizes it if
already applied, then applies MB1063. The full operator suite remains visible
with --progress and ETA. Security, startup, inventory and exact staging precede
the dev-only restart and native commit/push. VERSION stays in the native 3.8dev
flow; no production service, configuration, schema or dependency is changed.

These checks do not diagnose or change the separate ZNC service incident.
Host-specific local qualification limits are documented in the package.
