# MB992 — Honor timeout-first weighted poll syntax

Base: `snap_mediabot_v3_teuk_20261028_144909.zip`, VERSION
`3.6dev-20261028_134839`. This snapshot already contains MB991 and the French
Trivia integration. Only poll creation changes at runtime.

## Reproduced defect

The command help advertises a timeout followed by the optional weighted
keyword. The parser accepted weighted-first input only. For example:

```text
poll 60 weighted Lunch? | Pizza:3 | Sushi:1
```

This created an unweighted poll whose question was `weighted Lunch?` and
whose options were `Pizza:3` and `Sushi:1`. With one voter for Pizza and two
for Sushi, the real result and closing handlers selected Sushi, even though
the requested weights should give Pizza three points against Sushi's two.

The parser now recognizes the keyword after the timeout as well. Both forms
create the same weighted poll and deadline:

```text
poll 60 weighted Lunch? | Pizza:3 | Sushi:1
poll weighted 60 Lunch? | Pizza:3 | Sushi:1
```

The keyword is consumed once. In `poll weighted 60 weighted vote? | A:2 | B`,
the question remains `weighted vote?`. Existing timeout clamps (10–3600s),
default timeout (300s), omitted weight (one), unweighted literal colon labels,
authorization and empty-field refusal retain their behavior. No SQL,
configuration, dependency or Trivia changes are required.

## Verification

The regression contains 17 focused assertions using the real registered
poll/vote/result/stop handlers and Context authorization. A fixed child-local
clock checks exact deadlines. Public tally, final winner, close winner,
other-channel isolation, private input refusal, metrics and audit behavior
are covered without repeating a large matrix. Six assertions fail on the
original runtime; all pass with the parsing correction.

The delivery README records targeted and complete suite results, security
audit, startup integrity and command-inventory verification. No test is
excluded. The user procedure runs the entire suite with `--progress`, stops
on any failure, restarts dev only, then invokes the native commit/push script.
