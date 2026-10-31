# MB1042 — Target-scoped AntiFlood drain ownership

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_153517.zip`.
Base: `ed36797784543b113e81a46afb478dbae194e0f6` (MB1041),
VERSION `3.8dev-20261031_143237`.

DeferredOutput used one boolean _flood_draining marker while replaying a queued
PRIVMSG or ACTION. Any enqueue during that callback was then treated as a retry
of the active item: it was unshifted and skipped the normal capacity/timer path.
A reentrant callback writing to a different target therefore could leave that
new queue unarmed, overtake its older entries, or grow it beyond thirty items.
The original drain only rearms its own target and cannot repair the second one.

The existing local marker now contains the exact active target. Only a matching
target uses the historical head-reinsertion path. A different target appends via
its ordinary thirty-item cap and arm hook, retaining its existing timer when
already armed. The local value restores the previous context after the send.
No queue key normalization, timer-helper change, retry policy or new state key
is introduced. Production drain delay remains two seconds.

Fifteen assertions exercise the production IRC output facade, sender and queue.
A real Mediabot::Log console hook reenters that output path during an accepted
source-channel send. Tests cover fresh and already pending second targets,
overflow at thirty entries, FIFO and PRIVMSG/ACTION envelopes, accepted history
count, same-target reblocking, restored drain context and completion cleanup.
The normal policy/DB/wire integration fixtures are in-memory; no SQL server or
IRC connection is contacted. Most cases use deterministic timer fixtures;
one also executes real IO::Async countdown callbacks with only the delay
shortened to zero. Deterministic cases verify the original two-second delay.
Ten assertions fail before correction; all fifteen pass afterward.

The delivery requires the full --progress suite and audits before a dev-only
restart and native automatic 3.8dev commit/push. VERSION is not edited manually.
No production SQL/schema, configuration, dependency, radio or YouTube change.
