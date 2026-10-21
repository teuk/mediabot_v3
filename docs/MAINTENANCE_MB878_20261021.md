# MB878 — extract TMDB and share IRC text budgets

Base: `snap_mediabot_v3_teuk_20261021_133933.zip`, after MB877,
`3.6dev-20261021_113841`.

## Responsibilities and module ownership

Claude.pm contained 2,398 lines, including the unrelated TMDB catalogue
search, query repair and movie/series rendering. Its byte-budget helpers
were used by both the AI output paths and the TMDB correction from MB877.

| Module | Responsibility after extraction | Lines |
| --- | --- | ---: |
| `External/TMDB.pm` | Query repair, movie/TV search, metadata fallbacks and rendering | 219 |
| `IRC/TextBudget.pm` | Wire-byte measurement and bounded text prefixes | 47 |
| `External/Claude.pm` | Existing AI command adapters, conversation state and summaries | 2,157 |

Four functions move into TMDB.pm: `_repair_utf8_mojibake`, `mbTMDBSearch_ctx`,
`_tmdb_first_nonempty` and `get_tmdb_info`. Two helpers move into TextBudget:
`_irc_wire_bytes` and `_irc_prefix_for_budget`. All 45 original function bodies
are preserved byte for byte in their final owners. The copied xlogin heading
is removed, and TMDB-only imports move with their implementation.

TMDB can load without Claude, AI::Client or AI::Transport. TextBudget can load
without TMDB or Claude and delegates normal wrapping to the existing Helpers
splitter. It introduces no new renderer, transport or truncation policy.

The remaining AI adapters and summary behavior are kept together in this
round. No provider/client migration or summary-language redesign is included.

## Keep public and legacy interfaces

The External facade now imports TMDB directly from its owner. Its 33 public
exports are unchanged. Claude retains its 12 optional exports in the same
order, including the historical TMDB names, through aliases to the owner.
Existing fully qualified private calls to the title and byte-budget helpers
also remain usable through aliases to the same functions.

The built-in tmdb handler, direct facade calls, direct owner calls and old
Claude calls therefore reach one implementation. They retain configuration,
language lookup, HTTP factory, ten-second timeout, verified TLS, parser,
selection order, title/date fallbacks, finite ratings, reply target and the
MB877 UTF-8 budget. Shared AI/Partyline byte behavior also stays unchanged.

## Follow the implementation in tests and the TLS audit

Historical TMDB tests now inspect TMDB.pm. Mixed argument handling still
checks both the AI wrapper in Claude.pm and the catalogue wrapper in TMDB.pm.
The truncation helper regression inspects TextBudget.pm for its two moved
definitions while continuing to exercise the old Claude entry points.
Configuration and source-encoding inventories include the new owner.

The authenticated HTTP invariant previously scanned Claude.pm, which also
contained TMDB. It now scans both implementation owners and requires each
to contain its expected calls. A missing module or missing call cannot be
masked by the other owner's valid TLS configuration. The matrix remains 37
invariants; none is removed or made optional.

New offline regressions:

- `1300_mb878_tmdb_module_boundaries.t`: fresh-interpreter independent loads,
  legacy imports, three import orders, shared implementation identities,
  character/byte input accounting and tiny/normal prefix budgets.
- `1301_mb878_tmdb_compatibility_and_tls.t`: compare owner, facade, legacy and
  built-in command results, output, diagnostics, targets and HTTP options for
  healthy, Unicode, malformed optional, empty, malformed-root and HTTP-error
  responses. Run the real source audit on isolated public-source fixtures
  with TLS disabled, calls removed or a whole owner missing.

The MB877 fixture accepts an optional handler for those comparisons. Its
default remains the actual built-in command, so existing regressions keep
their execution path. No real API, IRC server or production DB is contacted.

No SQL schema, migration, private configuration, VERSION, service deployment
or test-runner change. No changes to the HTTP budgets, result contracts,
configuration bounds or business-function bodies. Executed results and local
limitations are recorded in the package's `QUALIFICATION.md`.
