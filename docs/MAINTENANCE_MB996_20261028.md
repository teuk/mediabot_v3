# MB996 — Require distinct outcomes for weighted choices

Base: `snap_mediabot_v3_teuk_20261028_171950.zip`, VERSION
`3.6dev-20261028_153233`. Earlier corrections remain present.

## Reproduced defect

Native choose and playful-v3 counted weighted pool entries when checking
whether at least two options remained. `choose solo:3` therefore performed
an accepted draw despite having only one possible result. It replaced last,
appended to history and, on the native path, logged a successful choice.
`solo:2 | SOLO:3` and `0:2 | 0` had the same problem.

Both handlers now count case-insensitively distinct result labels after
interpreting weights. This follows the existing case-insensitive duplicate
policy. Single-outcome input returns the existing private one-option notice
before any random draw, state change or successful native audit entry.

For valid input, pool entries and labels are not removed, combined or
reweighted. For example, `tea:2 | TEA:3 | café` retains its original six-slot
pool and original labels because it has two distinct outcomes. Display,
separators, empty-input refusal, zero recall and channel histories are
unchanged. playful-v3 advances from 1.0.2 to 1.0.3; activation, capabilities,
configuration, other commands and jobs are unchanged. No SQL, dependency,
Trivia, birthday or production deployment change is included.

## Verification

Twelve focused assertions use the registered native choose handler and real
PluginContext/InvocationV3 objects. Prior choices are seeded in two channels;
malformed choices must preserve complete last/history/audit state and consume
no random draw. Cases include plain/weighted duplicates, zero labels,
Unicode/case variants, French separators and empty input. Valid weighted
pools retain exact indices, labels, histories and scope with fixed draws.

Five assertions fail on the original implementation. After correcting native
choose alone, the same five still fail against the old v3 path, proving each
implementation separately. All twelve pass after both corrections.

The delivery README records targeted/full suite results, security audit,
startup integrity and command-inventory verification. No test is excluded.
The user procedure runs the complete suite with --progress and stops on any
failure before restarting dev and invoking native commit/push.
