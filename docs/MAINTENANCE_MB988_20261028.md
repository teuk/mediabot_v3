# MB988 — Remove forced alternation from playful-v3

Base: `snap_mediabot_v3_teuk_20261028_104535.zip`, VERSION
`3.6dev-20261028_085806`. The MB986 test reductions and MB987 calculator
correction are retained.

## Reproduced defect

The plugin's private random helper updated a 32-bit state with an odd
multiplier and an odd increment, then used the state modulo the requested
size. Modulo two, each update flips parity. Coins therefore alternate
mechanically, regardless of the initial seed:

- seed 1: `HTHTHTHTHT`;
- seed 42: `THTHTHTHTH`.

As a result, `flip 2` always returned one head and one tail; an even-sized
batch was always exactly balanced. Consecutive dice also alternated odd and
even faces, ruling out repeated faces even though each die should permit them.
The affected helper was shared by flips, rolls, choices, 8ball and the ritual.

## Change

Use `int(rand($size))`, as the built-in games already do, while preserving
the helper's existing minimum-size guard. Remove the private seed/state and
the obsolete seed assignment in the existing command-pack test. The plugin
does not call `srand` or reset the bot's random source.

The package version becomes 1.0.1. No activation defaults, operator ledger,
capability, command contract, job schedule or configuration changes are made.
The fix affects playful-v3 when it runs; built-in fallback code is unchanged.
Weighted choice pools, bounded histories, counters, channel scope and output
formatting retain their existing behavior.

## Verification

The new test adds 18 assertions and uses fixed random draws, with no sample
size thresholds, sleeps or statistical pass/fail probability. Actual plugin
command handlers are exercised through the real v3 invocation and reply
capability. Repeated heads/tails and repeated dice faces are possible, while
ranges, the ten-coin cap, counters, advantage, history and weighted choices
remain correct. The test fails against the original runtime and passes after
correction. It does not claim to certify a random generator statistically.

The targeted selection passes 150/150 assertions in nine files, including
reversible registry migration and ritual-policy tests. Security audit: GO,
all 37 invariants. Startup integrity and generated command inventory pass.
Full-suite results are recorded in the package README. The local process
checks 1151 and 828 also fail on the unchanged snapshot here.

No tests are excluded from the installation procedure. It stops at any
failure before restarting the dev service or invoking commit.sh, which
performs the native commit and push after confirmation.
