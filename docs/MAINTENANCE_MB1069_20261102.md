# MB1069 — Private command admission

## Defect

mbCommandPrivate called checkCmdCooldown with an undefined channel. That guard
returned zero before consulting any default, so repeated private ai commands
always reached their handler. The private wait notice existed but was never
reachable. Claude also names the same handler as ai without its own default,
allowing that alias to bypass the ten-second default in either command surface.

## Implementation

The existing helper accepts an optional fifth argument naming a private actor.
The dispatcher provides it before Context construction and handler/worker work.
Older calls without a channel and without an explicit actor still allocate no
global bucket. Public state keys and operator overrides retain their shape.
No public channel or nick-flood gate is added to the private dispatcher.

Private reservations use the monotonic clock, are keyed by command group and
the existing IRC nickname fold, and expire without depending on wall-clock
changes. Blocked calls round remaining seconds up and do not extend the deadline.
Users and public channels have independent scopes. ai and claude share the ai
group, including the existing partyline .cmdcooldown setter/reset path.

The private map has a fixed 1024-entry bound. Admission retires expired entries;
at capacity a new actor waits until the earliest expiry without evicting an
active reservation. Commands without a cooldown allocate no slot, so login,
identification, authentication and account administration retain their dispatch
path even when expensive commands are blocked. No configuration knob is added.
Existing block metrics are reused without per-nick labels or prompt logging.

## Validation and delivery

Replace the thirteen static assertions in 335 with thirteen native assertions.
Use the real Mediabot object, registry and private dispatcher, substituting only
terminal handlers and output/clock boundaries; SQL/IRC objects refuse all calls.
Exercise public AF4, repeated private dispatch, case/RFC1459 folding, independent
users/channels, ai/claude and the real partyline setter, fractional/exact expiry,
wall-clock rewind, unrestricted account workflows, bounded capacity and recovery,
legacy invalid/unscoped calls, metrics and warning/prompt isolation.
The handler substitutes prove admission ordering, not authentication internals.
No new file of tests or increase in assertion count.

Preserve all previous fixes, VERSION, private commit.sh, root README, full-suite
runner/ETA, radio and YouTube. No database schema, dependency installation or
configuration file changes. The operator script runs the visible full suite
with --progress/ETA and audits, then restarts dev only and invokes the installed
commit.sh with automatic 3.8dev VERSION after complete success.
See package QUALIFICATION.md for actual local results and limitations.
