# MB952 — Channel statistics with clear source owners

Date: 2026-10-24. Base: MB951, commit `d597b10`, version
`3.6dev-20261024_181840`, from the snapshot supplied after that push.

## Change

`UserCommands.pm` drops from 6,594 to 5,408 lines: 1,186 lines removed
from the facade (18%). Since the start of the refactoring chapter, it has
dropped from 7,885 to 5,408 lines (2,477 lines, 31%).

| Owner | Existing commands |
| --- | --- |
| `Mediabot/Stats/Activity.pm` | `mbStats_ctx`, `mbTop_ctx`, `mbActive_ctx`, `mbWhen_ctx`, `mbCompare_ctx`, `mbHeatmap_ctx`, `mbMonthStats_ctx` |
| `Mediabot/Stats/History.pm` | `mbWordCount_ctx`, `mbStreak_ctx`, `mbLast_ctx` |

The ten function bodies are byte-for-byte identical to the snapshot. The facade
imports the ten names, retains its export list, and exposes the same Mediabot
methods. The domain modules use late forwarding for the existing `botPrivmsg`,
`botNotice`, `logBot` and, for Activity, `getIdUser` hooks. Loading a domain alone
does not load `UserCommands` eagerly.

There is no SQL, archive policy, calendar, achievement, cache, schema or public
command change. `mbAlias_ctx` and the shared `_seconds_to_human` helper remain
in the facade. There are no new runtime dependencies, private configuration
changes, service actions or numbered test cases.

## Tests

Existing source assertions now inspect the owning module. Cross-domain archive,
public/action filter, cached-channel-id and date-predicate checks still cover
all their historical commands. No count threshold, SQL predicate or live-error
assertion is removed. Recursive pagination/encoding checks already cover the
new paths.

The existing MB574 case adds three fresh-interpreter checks: both domain-first
orders and the facade-first order. They verify ten alias identities, ten real
Mediabot methods and late notice interception through real command paths.

See `QUALIFICATION.md` in the delivery for exact local results and limitations.
The installation validator runs all changed Perl syntaxes, the command
inventory, targeted tests, the complete unfiltered suite, security audit and
startup integrity. A failure restores the files written by that attempt.

## Application

Use the guarded package as `mediabot` on `teuk.org`. The manifest checks exact
before/after bytes; existing modes are retained. An announced private backup
supports explicit rollback. Commit only after successful server validation.
Code loading and service restarts remain separate operations.
