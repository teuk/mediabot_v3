# MB1066 — Plugin event queue exception ownership

## Defect

EventQueueV3 caught plugin dispatch errors, then selected its diagnostic with
$@ || fallback outside that guard. A Perl exception object can overload boolean
conversion. If that conversion threw, the drain escaped while draining stayed
true; subsequent accepted events never scheduled another batch. A false-valued
exception object was silently replaced by a generic scalar instead of reaching
the error observer intact.

The scheduling failure path had the same conversion before resetting scheduled.
A defer implementation that retained its callback and threw such an object
could keep a failed arm active. Its retained callback could then process work
despite the caller having observed enqueue failure.

Even with scalar exceptions, repeated scheduling failures could fill the queue.
Its overflow branch always returned before retrying defer, so a full unarmed
queue remained blocked after the scheduling backend recovered.

## Implementation

Capture the original exception value directly. Use a generic fallback only for
an absent or empty scalar, checking references without invoking their overloads.
Pass dispatch failures intact to the existing guarded observer, which owns any
formatting. Retire the drain normally even if that observer also throws.

On defer failure, revoke only the arm's own generation and rethrow the original
exception unchanged. Preserve inline-completion/successor ownership, retained
work, one scheduled drain, FIFO, capacity and bounded batch behavior.

When the queue is full, keep dropping the incoming event, then retry scheduling
the retained backlog only if it is still nonempty, unarmed and not draining.
Recheck after the drop observer, which may clear or restart work reentrantly.

PluginManager already formats reference exceptions as a fixed scalar before
recording them. Its bridge, failure ledger and subsequent healthy event are
exercised together; no change to plugin policy, quarantine or event envelopes.

## Validation and delivery

Replace the existing sixteen assertions in
t/cases/1071_mb743_event_backpressure_queue.t with sixteen native assertions.
Retain the capacity/drop policy, scalar error observation, processed counters,
bounded batches and cancellation. Cover false-valued and throwing boolean/text
exception objects during dispatch and defer, an error observer that throws,
exact exception identity, zero implicit conversions, failed-arm stale callback
rejection, full-capacity retry and recovery of both retained and later work.

The real manager/hello-v3 event bridge must record one failure, process its
healthy successor, accept another event and still unmount its listener. Reuse
the existing offline loop/scheduler fixture rather than starting a server.
The separate real IO::Async/generation tests remain unchanged and active.

No new test file or additional assertion. Preserve MB1062/63/64/65 and earlier
qualified pending paths. VERSION, private commit.sh, README, radio and YouTube
stay unchanged. The operator script keeps the full suite visible with ETA,
then audits and inventory, dev-only restart and native 3.8dev commit/push after
success. No production service, schema, configuration or dependency change.
Package qualification records the actual local outcomes and limits.
