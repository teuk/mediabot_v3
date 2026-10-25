# MB955 — Level readers and profile views with clear source owners

Date: 2026-10-25. Reference: the confirmed MB954 code applied to the last
supplied snapshot. No newer server snapshot, VERSION or commit is inferred.
Exact before/after hashes protect the changed files; VERSION stays with
commit.sh and is not a payload.

## Extraction

| Owner | Existing functions |
| --- | --- |
| `Mediabot/Users/Levels.pm` | `getIdUserLevel`, `getLevelUser`, `getUserLevelDesc`, `getUserChannelLevel` |
| `Mediabot/Users/Profiles.pm` | `userStats_ctx`, `userInfo_ctx`, `userGreet_ctx` |

All seven bodies are byte-for-byte identical to the MB954 code. The remaining
43 bodies and the UserCommands export list are unchanged. The facade drops
from 4,104 to 3,730 lines, compared with 7,885 before the refactoring chapter.

Seven historical facade names and real Mediabot methods remain the same code
references. Profile transport, logging and truncation hooks resolve through
UserCommands at call time. Domain-first loading does not import the facade
prematurely. Existing administrative callers still use their original names.

Exact SQL and bind order, empty/error return values (including channel-level
zero versus undef), Context checks, password-presence-only projection,
hostmask LIMIT 20 and two-per-line pagination remain unchanged. Userstats
requires Master; userinfo requires Administrator; greet retains its original
requested-channel scope and private/public routing. Authorization policy in
Context/User and account mutations remain in their existing owners.

## Checks

SQL safety, exact-match, password and hostmask source tests follow their new
owners. The pagination migration guard still counts the original scope,
including Profiles after extraction, without reducing its thresholds.

The existing exact-level case adds three fresh-interpreter checks for both
domain-first orders and facade-first loading: seven aliases/methods, empty
input sentinels, actual Context authentication/level guards, late notices,
private greet syntax and absence of public output on denied paths.

The delivery's QUALIFICATION.md records exact local results and limitations.
The server validator retains changed Perl syntaxes, command inventory,
targeted tests, the complete unfiltered suite, security and startup integrity.

## Application

The installer checks all before/after bytes, announces a private backup and
preserves existing modes. Failed validation restores files written by that
attempt. Commit only after successful server validation; service actions stay
separate. There is no schema, SQL, permission, setting, activation or dependency
change in this extraction.
