# MB1110 — Public command cooldowns follow elapsed time

Public command admission previously subtracted two readings of the wall
clock. A jump forward could release an expensive command early; a jump
backward could leave a channel waiting after its configured delay.

The public guard now uses the same monotonic clock as the private guard.
The last admitted invocation remains the anchor. The configured duration
is compared with elapsed time and blocked replies round remaining time up
to whole seconds. Missing reservations and a legitimate stamp of zero are
distinct. Rejected attempts do not shift the deadline.

The per-channel keys, aliases, explicit durations, operator resets and
channel purge continue to use the same in-memory state. The separate
channel and nickname flood windows are outside this change. No database,
configuration or dependency change is needed.

The native fixture sets a public cooldown through the Partyline dispatcher,
moves the wall clock forward and backward independently of elapsed time,
and checks both fractional waits and admission at the exact expiry. The
same check fails with the original module. The fixture starts the monotonic
clock at zero to cover first and repeated admission.
