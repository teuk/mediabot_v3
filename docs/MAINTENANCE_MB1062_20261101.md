# MB1062 — Delayed automatic responders

Source: `snap_mediabot_v3_teuk_20261101_154719.zip`.
Snapshot VERSION: `3.8dev-20261101_144630`; not edited by this patch.

## Concrete failure

The ordinary public-message responder lane checked its ten-minute cooldown
when receiving a message. Its last-response timestamp was only advanced by
`doResponder`, after a later 2–9 second countdown. Three qualifying messages
inside that delay therefore armed three independent timers. Their callbacks
never rechecked the cooldown or their IRC/channel lifecycle, so all three
could answer in a burst and old work could send into a replacement session.

The new `scheduleResponder` method in DBCommands owns one pending reservation
for this existing instance-wide cooldown. The main callback delegates its
old inline timer to this owner. No channel-specific cooldown is introduced.

## Ownership and delivery

- Reserve before construction/add/start; release partial registrations on
  failure, including a timer already attached or started before an exception.
- Retain the slot while doResponder executes, and consume the callback once.
  Reentry cannot arm another timer before doResponder records its timestamp.
- At expiry, reuse IRC::DeliveryContext for the captured transport and joined
  channel generation, then recheck the existing 600-second cooldown.
- A duplicate or superseded callback cannot send, remove another timer or
  consume a replacement reservation. Completed countdowns leave the loop.
- onStartTimers cancels a previous pending responder before querying TIMERS;
  failure to reload those independent DB timers cannot revive the old reply.
  The existing atomic reload/rollback of periodic DB timers stays unchanged.
- Timer callbacks hold weak bot/reservation references. A pending timer does
  not extend its bot's lifetime. New failure diagnostics contain fixed labels,
  not underlying exception text, and a broken logger cannot escape cleanup.

The chance calculation, exact responder matching, 2–9 second random delay,
add/delete commands, rendering and existing doResponder SQL/timestamp behavior
remain unchanged. A failure that did not record a successful response frees
its slot; this patch does not manufacture a new ten-minute failure cooldown.
playRadio, YouTube, README, VERSION, schema/config/dependencies and production
services are outside the change.

## Focused evidence

One new native case executes the actual responder branch from mediabot.pl with
real IO::Async countdowns, loop membership and the shared conversation runtime.
It does not use a copied scheduling algorithm or pin a historical comment.
A virtual policy clock tests the 599/600-second boundary without waiting ten
minutes. One actual short native expiry plus a heartbeat checks the event loop;
only that fixture's first timer occurrence is accelerated, not the production
2–9 second policy. The bot's actual responder body is spied at the delivery
boundary so these scheduling tests require no server/SQL data.

The 25 assertions cover the burst/first request, one-shot delivery and cleanup,
the exact cooldown boundary and recheck, stale transport/channel/shutdown,
login cancellation including a failed DB reload, partial add/start failures,
callback/logger failure with recovery, reentry and weak owner lifetime.
On the original snapshot they expose 19 failures; after correction all pass.
The surrounding responder/export/timer/exclusion/delivery tests are retained.

See delivered QUALIFICATION.md for complete validation and known local limits.
The operator script runs a visible full suite with --progress/ETA, audits,
then dev-only restart and the installed native commit.sh after success.
VERSION stays native-managed in 3.8dev. A stable PID is not IRC reconnection proof.
