# MB1056 — One channel identity for AF4 input-flood protection

Date: 2026-11-01 (Europe/Paris)

## Defect

`checkChanFlood` previously addressed `_chan_flood` and `_chan_flood_conf`
with the caller's exact channel spelling. `#Room`, `#room` and `#ROOM`
therefore created separate sliding windows and silences. A partyline setting
for one spelling did not reliably govern commands received with another.
Reconfiguring the channel with different letter casing also reset a different
state entry and could leave the active silence untouched.

## Implementation

Resolve one lowercase channel key at the AF4 guard boundary. Use it for both
the active state and the entire operator override, including warn-only. Keep
the original incoming spelling for logs and console events.

Resolve the same lowercase key in the native `.floodset` implementation for
storing the override and deleting the active window. Keep the operator's
spelling in the established confirmation. Repeated settings replace one
channel policy instead of adding case aliases. The existing floodstatus
listing consequently reports a single canonical AF4 entry.

This follows the project's existing lowercase channel convention; it does
not introduce a new IRC CASEMAPPING policy or merge punctuation variants.
The historical #channel-only admission boundary, threshold comparison,
sliding-window pruning, silence duration, exact expiry, notification cooldown,
metrics, minimum-value clamping and warn-only behavior remain in place.
Output AntiFlood, command cooldowns, nickname strikes/mutes and authorization
are not changed. Other channels retain their own settings and active windows.

These dictionaries are process-local. Normal deployment restarts the dev
process after successful tests; no persistent data or state format is migrated.
This patch is not a change to `.floodset` parsing or its authorization policy.

## Native regression evidence

Case `1429_mb1056_channel_flood_identity.t` executes the real partyline
dispatcher, its `.floodset` and `.floodstatus` implementations, the Helpers
facade and the owning CommandThrottle implementation. A controlled clock
checks exact deadlines without waiting. Transport/log/config/metrics sinks
are local; unexpected database or IRC operations throw immediately.

Thirty-three assertions cover shared mixed-case defaults, threshold and
silence, notification throttling, exact expiry, native operator settings,
preserved confirmation spelling, immediate reset/reconfiguration, status
reporting, independent channels, warn-only behavior, return to defaults,
minimum clamping, the unchanged #channel boundary and warning-free execution.
Twenty-two fail on the original runtime; all pass after correction.
No historical assertion is modified, removed or disabled.

## Delivery

Scope: CommandThrottle, partyline Commands, CHANGELOG, this note and one
new native test. The supplied operator script requires the visible full
`--progress` suite, security/startup audits, generated command inventory and
whitespace checks before restarting `mediabot@dev.service`. It then requires
a different positive PID stable for ten seconds before the installed
interactive `commit.sh --skip-preflight` handles commit/push and the next
native 3.8dev VERSION. Do not manually edit VERSION. Process stability alone
does not prove IRC reconnection.

No project README, schema, configuration, dependencies, production, radio or
YouTube change. No private commit helper is distributed. Detailed local
results and environment limits are in the package's QUALIFICATION.md.
