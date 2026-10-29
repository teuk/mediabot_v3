# MB1006 — Keep chance-game numeric tokens consistent with arithmetic

Base: `snap_mediabot_v3_teuk_20261029_101302.zip`,
VERSION `3.6dev-20261029_084754`; MB1005 is already present.

## Reproduced defect

`roll`, `flip` and weighted `choose` accepted Unicode decimal digits through
Perl's `\d`, then passed them to numeric comparison, `int`, repetition or
arithmetic. Those operations do not interpret such strings as the intended
decimal integer. For example, `roll ٢d8` became a one-die, eight-face roll;
mixed forms could keep only an ASCII prefix and silently change a dice
parameter, signed bonus or weight while emitting numeric warnings.

## Correction and scope

The numeric fields now match `[0-9]` in both
`Mediabot/Games/Chance.pm` and `plugins/playful-v3/lib/Playful.pm`:

- Number and sides of explicit dice, and shorthand sides.
- Signed roll modifiers and flip counts.
- The numeric suffix of weighted choices.

This follows the existing handling of unrecognized tokens: an invalid dice
token leaves the default `1d6`, invalid modifiers are ignored, an invalid
flip count leaves one coin, and an invalid weight suffix stays part of the
literal choice label. No transliteration, new error response or change to
the random source is introduced. Valid ASCII tokens retain their limits,
modifiers, advantage/disadvantage, draws, histories, counters and native
audit entries. Choice labels still support Unicode text. Existing anchors,
separators, deduplication, distinct-label validation and channel routing are
unchanged. The plugin manifest version moves from `1.0.3` to `1.0.4`; its
capabilities, policies, configuration schema and boot ledger do not change.

No database schema, SQL, deployment configuration, dependency or other game
changes. The root README, radio and YouTube code are unchanged.

## Validation

`t/cases/1381_mb1006_chance_numeric_tokens.t` adds ten assertions using the
real native public registry and the actual plugin handlers with API v3
Invocation/PluginContext. A deterministic random fixture records bounds
and consumption; no statistical thresholds or network calls are used.

Cases include Arabic-Indic, fullwidth and mixed digits in every affected
numeric position, warnings, unchanged invocation arguments, ASCII controls,
clamping, nonnumeric fallback, Unicode labels, recorded rolls, choices,
flip counters and native auditing. Six assertions fail before the fix;
all ten pass afterward. This test does not use IRC or a database server.

The delivery README records targeted and complete suite results, security,
startup integrity, command inventory and any failures reproduced on the
unchanged snapshot in this environment. No existing test is removed or
skipped. The patch is checked forward and in reverse, including exact file
bytes and executable bits; the native credential scanner is retained.

The supplied procedure restarts dev only, after the complete suite and
native checks pass, then invokes native `commit.sh` for commit and push.
No deployment or Git publication is performed in this preparation workspace.
