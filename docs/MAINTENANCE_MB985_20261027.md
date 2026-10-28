# MB985 — Confirm the complete duel karma pair

## Reproduced defect

Native `duel` executed two separate autocommitted UPSERTs: +1 for the winner,
then -1 for the loser. If the second statement failed, the winner's point
remained committed. With non-throwing DBI errors, the handler still announced
success and advanced statistics, streaks, the 24-hour cooldown and achievements.
With throwing errors, the exception could escape after the first change.

The regression forces an actual losing-row constraint failure on SQLite.
An independent connection observes the old winner's score changing from 10
to 11 while the loser stays at 0. The corrected statement leaves both unchanged.
The SQLite constraint is a private fault fixture, not a runtime schema change.

## Correction and limits

Only `Mediabot/Games/Duel.pm::mbDuel_ctx` changes at runtime:

- Submit +1 and -1 in one parameterized multi-row UPSERT using `VALUES(score)`.
  The canonical `KARMA` table already uses InnoDB and its unique channel/nick
  key. Statement atomicity replaces the two independent commits.
- Require the normal DBI autocommit context, a known channel and an available
  handle. Do not commit or roll back another caller's transaction.
- Require the expected affected-row count (2–4, including MariaDB's inserted
  versus updated-row reporting) and inspect DBI error status before cleanup.
  Only a confirmed result advances gameplay state or publishes a winner.
- Contain write failures and attempt cursor cleanup independently. The fixed
  notice says the result was not confirmed and asks to check karma before
  retrying. Raw driver details are not printed or logged by this failure path.
- Never resubmit an uncertain write automatically. If the server committed
  but its acknowledgement was lost, both score changes can already exist;
  the handler does not claim success or repeat them. No new durable receipt
  or exactly-once guarantee across a subsequent manual retry is introduced.
- Preserve a confirmed result if only cleanup fails. Keep the optional karma
  achievement read contained and use its score only after a confirmed read.

Dice display, draws, critical/fumble bonuses, opponent/presence checks, Games
policy, channel isolation, cooldown duration and existing achievement rules
remain. No DDL, schema migration, settings, permission or plugin change.

The statement uses MariaDB's documented multi-row UPSERT and `VALUES()` rules:
<https://mariadb.com/docs/server/reference/sql-statements/data-manipulation/inserting-loading-data/insert-on-duplicate-key-update>.
Its atomicity relies on the existing canonical transactional table; this patch
does not convert noncanonical storage engines or change driver reconnect policy.

## Validation

`t/cases/1361_mb985_duel_atomic_karma.t` exercises the domain, UserCommands and
bot facades and the actual registry. A SQL-dialect-only bridge lets SQLite
execute real writes while another connection observes committed scores.

Coverage includes existing/missing/mixed score rows, either winner, both DBI
error modes, a genuine second-row SQL failure, missing prerequisites, a caller
transaction, unexpected affected counts, lost acknowledgements, cleanup faults,
optional achievement-read faults, channel isolation, draws, critical/fumble
output, cooldown and underdog streak transitions. No IRC or SQL server was contacted.

- New regression: **554 assertions pass**, **189 fail** on the input snapshot.
- Targeted suite: **2,316/2,316**, 16 files.
- Full suite: **54,711/54,713**, 1,203 files, 205 seconds. Only
  `1151_mb786_production_update_state_preservation_contract.t` and
  `828_mb647_doctor_core_local_probes.t` fail. Both failures also reproduce
  on the unchanged input snapshot in this runner; 828 passed the initial
  two-file baseline check, then failed on an isolated baseline recheck.
  No test exclusion or environment workaround is added to the operator flow.
- Security audit: **GO, all 37 invariants hold**.
- Startup integrity and generated command inventory: verified.

Input: `snap_mediabot_v3_teuk_20261027_213934.zip`, whose latest maintenance
entry is MB983. This patch follows that exact snapshot; it does not bundle the
separately delivered MB984 French Trivia feature. Application README,
`mediabot.pl`, quote code, radio, YouTube and the dictionary game are unchanged.
The delivery README contains the full guarded application, visible full-suite,
dev-only restart and native `commit.sh` procedure.
