# MB882 — Owned countdowns for reliable IRC output

Base: `snap_mediabot_v3_teuk_20261021_152453.zip`, after MB881,
`3.6dev-20261021_132411`.

The output extraction exposed lifecycle problems in the existing timers.
This round shares their one-shot ownership mechanics while retaining each
queue's separate delivery policy.

## Reproduced failures

The original snapshot, tested with actual IO::Async loops, retains the expired
AntiFlood countdown as a registered notifier. A start exception also leaves
an attached notifier in all three output queues; paced PRIVMSG remains active
and AntiFlood remains armed without a running timer. A NOTICE send exception
leaves its timer in both the loop and the tracked NOTICE slots.

The targeted fix is `Mediabot::IRC::Timer::countdown`. It owns construction,
addition, start and terminal cleanup of a single countdown. It attempts
stop/removal after a partial setup failure and removes an expired timer before
running its callback. It releases captured callbacks and timers before user
code can throw; retained expiry callbacks cannot replay completed or failed
work. Original exception objects propagate unchanged. Cleanup exceptions are
suppressed so they cannot replace the original failure; a broken loop that
refuses removal cannot be guaranteed to release its notifier.

The module has no Helpers dependency and loads IO::Async only when requested.
Its returned timer is single-use. It defines no rate, retry, sender, fallback,
shutdown or general cancellation policy. Existing periodic or independently
cancellable timers elsewhere are deliberately not converted.

## Queue policies and recovery

| Queue | Normal behavior retained | Behavior after an exceptional exit |
| --- | --- | --- |
| Paced PRIVMSG | First chunk immediate; later chunks and replies serialized per lowercase target; each batch retains its delay. | Setup error propagates; inactive state retains unattempted chunks and waiting batches. The next paced request resumes them before new work. No automatic retry or immediate burst. |
| Queued NOTICE | First line scheduled; 1.5-second spacing; sixteen-line cap; current global pending-slot accounting, including reentrant sends. | Any timer setup failure, now including construction, uses immediate fallback for that line. A send exception propagates after freeing its timer slot. Other scheduled lines remain available to the loop. |
| AntiFlood | Exact target keys; thirty-item cap; one item per two-second arm; mixed PRIVMSG/ACTION order; blocked item returned to the head. | Failed setup clears the armed flag and retains pending data. A send exception rearms remaining items and propagates the original failure. The attempted item is not replayed because the transport may have sent it before throwing. |

Paced recovery requires another request that qualifies for paced scheduling;
the missing-loop and immediate-send branches retain their existing behavior.
AntiFlood recovery from a setup failure uses the existing arm hook or a later
deferred enqueue. There is no new recovery scheduler. Exceptions remain visible;
these changes do not promise continued execution if the outer event-loop owner
chooses to terminate on an exception.

```perl
use Mediabot::IRC::Timer qw(countdown);

countdown(
    loop => $loop,
    delay => 1.5,
    on_expire => sub { ... },
);
```

Use this only when that single-use lifecycle matches the caller. Feature output
still goes through Output/Helpers/Context; code must not bypass Sender policy
or worker collection. Public output wrappers, three sender bodies, all text
budgets, encodings, CTCP ACTION envelopes, NoColors/badword rules, metrics,
private redaction and return conventions remain unchanged. No SQL changes.

## Verification

Three new regressions cover timer creation/add/start failures, partial native
attachment, original exception identity, stale callbacks, memory ownership,
queued recovery, reentrant NOTICE spacing, exceptional sends, and fifty native
AntiFlood expiration cycles using mixed output kinds. They exercise production
code with deterministic IO seams and actual IO::Async loops. Native lifecycle
tests use zero-delay timers; separate tests assert the production delays.

Historical MB312/MB326 source checks follow the new timer owner. The MB881 IO
fixture now supplies the removal operation of the real loop. MB391 requires
modules by their canonical names: previously its isolated run could reload
Helpers under two require keys and replace its localized IO stubs. Its existing
assertions are retained. No historical case is removed or excluded.

The same 1,537 before/after comparisons of text, encoding, rendering, targets,
redaction, queue traces and return values match. This is sampled compatibility
evidence, complemented by the full suite, not proof for every possible input.
See the package's `QUALIFICATION.md` for exact results and local limitations.

No migration, private configuration, VERSION, service or test runner change is
included. Installation performs no commit, push or bot restart.
