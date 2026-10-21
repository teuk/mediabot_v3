# MB879 — Share IRC text budgets without changing presentation

The review starts from the post-MB878 snapshot
`snap_mediabot_v3_teuk_20261021_135810.zip`, version
`3.6dev-20261021_115726`. The goal is compatible reuse, with each caller's
existing behavior taking priority over the number of direct imports.

## What the review found

TextBudget initially held two helpers used by Claude and TMDB. Helpers
already provided the common splitter used by PRIVMSG, NOTICE and ACTION,
and the legacy `truncate_utf8` used by many command/history renderers.
Those paths were already shared, but the dependency ran from TextBudget
back into the much larger Helpers module.

There are also two different byte-counting conventions. Their distinction
is intentional and must not be collapsed merely because both mention UTF-8.

| Primitive | Input and preserved contract |
| --- | --- |
| `_irc_wire_bytes` | Flagged character strings are encoded; unflagged strings are already wire bytes. |
| `_utf8_text_bytes` | Application character text is explicitly encoded as UTF-8, including unflagged Latin-1 characters. |
| `_split_text_for_irc` | Existing word wrapping, single-line normalization, 400-byte default and budgets below 16 normalized to that default. |
| `_irc_prefix_for_budget` | Existing first wrapped chunk for normal budgets; existing small-budget path. |
| `truncate_utf8` | Existing character/raw-UTF-8 handling; `max` bounds content and the suffix is appended outside it. Nonpositive max retains its historical meaning. |

For example, an unflagged scalar containing byte E9 costs one wire byte but
two bytes when treated as the character U+00E9 and explicitly UTF-8 encoded.
Conversely, explicitly encoding an already encoded buffer would double-encode
it. A common measurement must be selected by the caller's existing contract.

## Ownership and compatible adoption

TextBudget now owns the existing sanitizer, word splitter and legacy
truncator. It depends only on Perl/Encode/Exporter, with no Helpers, bot,
database, AI provider or network dependency. Helpers keeps callable wrappers
and its existing exports. Existing users of those helpers reach the common
implementation without modifying their command logic.

AI::IRCOutput keeps its `_wire_bytes` compatibility wrapper and uses the
wire counter. Its shared splitter now comes directly from TextBudget, as
does Claude's compatibility wrapping path. Claude and TMDB retain the two
imports introduced in MB878.

The explicit character counter is shared by AI::MetaReply, AI::MetaRuntime,
External::Horoscope, External::News, External::NewsBulletin, PluginContext,
RSS, RSS::Runtime, RandomQuote::Runtime, UserCommands and VDM. News and
UserCommands keep their existing private counter entry points. These changes
replace equivalent measurements, leaving each surrounding algorithm intact.

Two historical source checks follow the new splitter owner. The standalone
AI rendering test uses the actual pure splitter instead of installing a
global Helpers stub for a dependency it no longer needs.

## Policies deliberately preserved

- Horoscope still fits complete grapheme clusters and applies its own word,
  punctuation and ellipsis rules. Its tiny-budget behavior is unchanged.
- News keeps its own codepoint truncation and historical tiny-budget
  ellipsis fallback. This round does not optimize or redefine that method.
- AI output keeps its Markdown handling, balanced styles, suffix reservation
  and maximum two lines. No renderer is replaced with a generic truncator.
- RSS keeps the URL whole, reduces title/label as before, and rejects a line
  if the intact URL cannot fit. PluginContext and VDM retain rejection rules.
- Random quotes keep their existing prefix and explicit suffix reservation.
- The DTC formatter and Radio's existing fitting methods remain unchanged.
  Existing `encode_utf8` callers are not mechanically converted to strict
  `encode('UTF-8', ...)`; their encoding policies are left alone.
- Database/storage validation, hashes, HTTP Content-Length, prompt limits,
  Partyline limits and actual transport encoding are outside this reuse.
  They do not all express an IRC display budget.

## Validation

Two new offline tests exercise pure loading and import order, the distinct
character/wire conventions, encoded buffers and downgraded Latin-1, legacy
wrappers, content-only suffix limits, default budgets, sanitation and actual
consumer boundaries. They include horoscope family emoji, news's distinct
cutting behavior, plugin rejection, styled AI/meta output, intact RSS URLs
and VDM rejection.

A separate before/after comparison executes the original snapshot and the
candidate in separate Perl processes. Its 1,226 cases compare values, wire
bytes, scalar UTF-8 flags, warnings and errors. They cover the shared core,
AI/meta presentation, horoscope, news, plugin output, leaderboard accounting,
RSS and VDM, with small/default budgets, Unicode, raw UTF-8, Latin-1,
combining characters, family emoji, IRC styles and line controls. All cases
match. This is sampled equivalence evidence, not proof of every possible input.

The delivery qualification records complete-suite and environment results.
The server installer requires the unfiltered full suite, security audit and
startup integrity check. No failed test is accepted or excluded there.

No SQL schema, migration, private configuration, service, VERSION or test
runner change is included.
