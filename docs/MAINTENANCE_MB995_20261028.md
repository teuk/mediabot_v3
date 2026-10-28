# MB995 — Recall zero as a valid native choice

Base: `snap_mediabot_v3_teuk_20261028_160546.zip`, VERSION
`3.6dev-20261028_150526`. Previous corrections remain present.

## Reproduced defect

Native `choose 0 | 1` can legitimately select and record the label `0`.
Its rolling history then reports zero, but `choose last` claimed there was
no previous choice. The same mismatch occurred after choosing the zero
label from a weighted option such as `0:2 | café`.

The recall branch tested the stored string as a Boolean. It now checks
whether the value is defined. A zero is retained; an absent result keeps
the established no-previous-choice reply.

Only this guard changes at runtime in `Mediabot/Games/Chance.pm`. Drawing,
weights, deduplication, separators, stored values, rolling history, channel
scope and native audit behavior are unchanged. playful-v3 already uses a
definedness check and is unchanged, as are dice, birthdays and Trivia.
No SQL, configuration, dependency or production rollout changes.

## Verification

Nine focused assertions invoke the actual registered native choose handler
with real Context objects and fixed test-only draws. They reproduce plain
and weighted zero recall, verify the original public result/history/audit,
prove last/history queries consume no draw and preserve state, check a
separate channel, and verify that a later Unicode label replaces last while
preserving earlier zeros. Two assertions fail on the original runtime;
all nine pass after correction.

The delivery README records targeted and complete suite results, security
audit, startup integrity and generated command-inventory verification.
No test is excluded. The user procedure runs the complete suite with
--progress and stops on failure before dev restart and native commit/push.
