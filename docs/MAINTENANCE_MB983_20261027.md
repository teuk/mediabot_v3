# MB983 — Stop the complete Trivia game lifecycle

## Reproduced defect

`trivia start 3` creates series metadata before asynchronously fetching its
first question. `triviastop` invalidated the pending request token, but returned
early when no question was active. It retained `multi_total`, `multi_current`
and session scores. A later plain `trivia` request then resumed the supposedly
cancelled series. Stopping between answered or expired questions had the same
defect and misleadingly reported that no game was active.

## Correction

Only `Mediabot/Games/Trivia.pm::mbTriviaStop_ctx` changes at runtime:

- Keep the existing authenticated Master authorization before any mutation.
- Treat an active question, pending request or unfinished series as stoppable.
- Invalidate the selected channel's request and clear its unfinished series
  counters, session scores and hint state in every such phase.
- Keep the existing public answer reveal when stopping an active question and
  private cancellation notice when cancelling a pending request. A series
  between questions receives `Trivia game stopped.` without revealing an old
  answer. Repeated stops remain harmless.
- Reuse the existing callback token guard, which rejects late successful,
  failed and duplicate completions, even when a newer request is pending.

Cancellation does not delete earned `TRIVIA_SCORES` points or affect another
channel. A completed game's session scoreboard remains queryable when there is
no question, pending request or unfinished series to stop. No DB migration,
HTTP implementation, automatic next-question policy or plugin state changes.

## Validation

`t/cases/1359_mb983_trivia_stop_lifecycle.t` uses the real command lifecycle
through the domain, legacy and bot facades and the actual command registry.
Only asynchronous completion and transport are controlled. An actual SQLite
database executes answer-score writes with an UPSERT dialect translation.

Coverage includes the first pending question, a subsequent pending question,
the interval after an answer, a timed-out round and a live question. It checks
request invalidation, cleanup, fresh-question restart, late/duplicate callbacks,
channel isolation, access control and retention of already earned points.

- Regression: **580 assertions pass**, with **124 failures** on the original
  snapshot `snap_mediabot_v3_teuk_20261027_201608.zip`.
- Targeted suite: **1,508/1,508**, 11 files.
- Full suite: **54,158/54,159**, 1,202 files, 211 seconds. The only failure is
  `1151_mb786_production_update_state_preservation_contract.t`; the same
  updater-rehearsal failure occurs on the unmodified input snapshot in this
  runner. No exclusion or workaround is added to the operator commands.
- Security audit: **GO, all 37 invariants hold**.
- Startup integrity and generated command inventory: verified.

The delivery patch also includes this note, its regression test and the
changelog entry. The application README, quote code, dictionary game and
`mediabot.pl` remain byte-for-byte unchanged.

## Application

Apply the delivery patch as `mediabot@teuk`, then run the entire suite with
`perl t/test_commands.pl --progress`, the security audit and startup integrity
check before restarting only `mediabot@dev.service`. Stage the new note and
regression test, then use the native `commit.sh --skip-preflight` workflow.
Any failure must stop the sequence before restart or commit. The delivery
README includes the complete, repeatable operator commands.
