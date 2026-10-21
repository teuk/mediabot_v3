# MB883 — Ordered replies through the shared IRC pacing queue

Base: `snap_mediabot_v3_teuk_20261021_154940.zip`, after MB882,
`3.6dev-20261021_134906`.

## Reproduced ordering defect

The existing pacing code chose immediate delivery whenever the new batch
contained only one retained chunk or requested a zero/invalid delay. That
choice happened before consulting the target's pending queue.

For example, enqueueing `[old1, old2, old3]` with pacing, then `[new]`, produced
`old1, new, old2, old3`. A later zero-delay batch could similarly interrupt an
older reply. After an arm failure, a single-line recovery request was emitted
while the older unsent chunks remained stranded in the inactive queue.

MB883 first checks whether this target already has active or pending work.
Later single-chunk and zero-delay batches join that work instead of bypassing
it. The examples now finish `old1, old2, old3, new`. A single or zero-delay
request can resume an inactive queue when a scheduling loop is available.
An active queue keeps its existing timer/loop owner, including when the bot
no longer exposes that loop through its lookup; no competing timer is added.

## Compatibility boundary

Only existing-work precedence changes. With an idle target, a single reply or
zero-delay batch remains immediate, creates no queue state and starts no timer.
A different target remains independent. Empty input still returns zero without
altering pending work. Missing-loop fallback remains immediate if no active
queue owns this target; inactive pending work requires a usable loop to resume.

Target keys retain lowercase identity, without a change to RFC case mapping.
An existing owner retains the original target spelling used for its sends.
The chunk count result, filtering of undefined/empty entries, scalar `0`,
input arrays and per-batch delays retain their contracts. The gap between two
batches continues to use the completed batch's delay. A zero-delay batch behind
older work waits for its turn, then uses zero-delay countdowns within its own
batch and at its next boundary. No sleep or new rate policy is introduced.

The pump, timer cleanup, error propagation/recovery and send exception policies
are unchanged. A repeated arm failure retains all unattempted data and waiting
batches; a subsequent request can resume them. Attempted sends are not replayed.
All actual sends continue through Output and the dynamic Helpers facade, so
current filters, encoding, metrics, history and worker interception still apply.

NOTICE, AntiFlood, Timer, Sender, Helpers, TextBudget, AI rendering, specialized
conversation expiry and database code are untouched. This is not a merger of
those queues or an acknowledgement/cancellation redesign.

## Tests

Two new cases execute production pacing code with deterministic timers and real
IO::Async notifiers. They cover short replies, zero/undefined/negative/malformed
delays, filtered scalar zero, same-target casing, separate targets, idle and
missing-loop behavior, a retained active owner, reentrant enqueue, each timer
setup failure stage, repeated failed recovery, native ordering, input/encoding
preservation, current NoColors/badword policy and stale callback cleanup.

Both new cases fail against the original snapshot and pass against the candidate.
The existing MB880/881/882 regressions remain unchanged. The historical 1,537
sampled before/after comparisons still match; the new ordering scenarios are
covered explicitly because their previous results are intentionally corrected.
No historical case is removed or excluded.

See the package's `QUALIFICATION.md` for full results and the preexisting local
MB786 limitation. Server installation requires the complete unfiltered suite,
security audit and startup integrity to pass, and restores the attempted writes
if validation fails.

No SQL schema, migration, private configuration, VERSION, service, test runner,
commit, push or restart change is included.
