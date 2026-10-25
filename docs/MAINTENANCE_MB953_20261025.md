# MB953 — Dedicated source owners for small games and duels

Date: 2026-10-25. Reference: MB952 snapshot supplied after installation,
VERSION `3.6dev-20261025_043439`.

## Extraction

| Owner | Existing command handlers |
| --- | --- |
| `Mediabot/Games/Chance.pm` | `mb8ball_ctx`, `mbSlap_ctx`, `mbRoll_ctx`, `mbFlip_ctx`, `mbChoose_ctx` |
| `Mediabot/Games/Duel.pm` | `mbDuel_ctx` |

The six bodies are byte-for-byte identical to the supplied snapshot. The
remaining 58 functions and the export list in UserCommands are unchanged.
The facade drops from 5,408 to 4,841 lines (567 lines, 10.5%). Since MB951,
UserCommands has dropped from 7,885 to 4,841 lines (3,044 lines, 38.6%).

Domain exports retain the existing command names. Transport hooks resolve the
historical UserCommands symbols at call time; Duel does the same for
`_ach_progress`. Domain-first loading does not eagerly import the facade.
Dice rolls, coin flips, choices, language selection, action rendering, karma
SQL, duel cooldowns, achievements and in-memory history use the original code.
The separately activated playful-v3 implementation and its policy are unchanged.

## Regression checks

Source checks for dice formatting, 8ball language/encoding and persistent
achievement progress follow their actual implementation. The cached-channel-id
migration check still includes Duel after extraction. Recursive repository
encoding and pagination guards cover the new modules.

The existing MB425 case adds three fresh-interpreter checks for load order,
six legacy aliases, six real Mediabot methods and actual game paths: bounded
histories, per-channel state, native dice formatting, choice deduplication,
transport hooks and duel guards. No numbered case or alternate runner is added.

The delivery's QUALIFICATION.md records exact local results, native trace
comparisons and any environment-dependent failures. Server validation remains
mandatory: changed Perl syntaxes, command inventory, targeted tests, the complete
unfiltered suite, security audit and startup integrity.

## Application

The guarded package uses exact before/after hashes and announces a private
backup. It preserves existing modes and restores files written by an attempt
if validation fails. Commit only after successful server validation; VERSION
is managed by commit.sh. Service restarts remain a separate operation.

No schema, private setting, dependency, activation or live instance is changed
by preparation of this code package.
