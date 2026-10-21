# MB885 — Bounded work in the shared IRC text budget

Date: 2026-10-21. Base: MB884,
`snap_mediabot_v3_teuk_20261021_165637.zip`,
VERSION `3.6dev-20261021_145554`.

## Problem and change

`IRC::TextBudget::_split_text_for_irc` encoded the entire remaining buffer
to decide whether to split again. Its character loop also materialized every
remaining character, although only the next wire-sized prefix was needed.
Both operations repeated for each output chunk. Prefix-only callers invoked
the whole splitter and discarded every chunk after the first.

A private `_irc_chunk_prefix` now owns the existing next-chunk decision.
It inspects at most `budget + 1` characters: each character occupies at least
one wire byte, so this window suffices to determine whether a cut is required.
The existing per-character cost and half-prefix whitespace rule determine
the cut. Full wrapping consumes successive chunks; normal-budget prefix
requests stop after the first decision. The whole-message fit check remains.

The window limits accounting and character scanning for each decision. This
does not impose an input size limit, change the number of delivered chunks,
or claim bounded total work regardless of input length. Prefix requests still
inspect the full input for the initial fit check and, on overflow, sanitation.
The existing tiny-budget path is retained.

## Compatibility boundaries

- The default remains 400 bytes and invalid or sub-16 wrapping budgets retain
  their original normalization. Prefix-only budget validation stays stricter.
- Raw byte buffers remain raw, including invalid UTF-8. Character strings use
  the original byte costs and Unicode whitespace rules. No decode/re-encode
  conversion is introduced. Non-Unicode code points retain legacy handling.
- Word-break preference, the half-prefix threshold, whitespace retained at a
  cut and whitespace discarded before the next chunk remain unchanged.
- A final ASCII tail of a Unicode message keeps its existing representation.
  Normalization of wholly ASCII strings keeps its historical flag behavior.
  Returned prefixes are taken from the original working buffer, not a
  temporary window whose UTF-8 flag Perl may downgrade.
- Full wrapping sanitizes before its fit check. Prefix-only calls still return
  the original text unchanged if it already fits, and sanitize an overflowing
  normal-budget input before choosing a cut.
- List results and legacy scalar results are preserved: a fitting input returns
  its string in scalar context; a wrapped input returns the chunk count.
- `truncate_utf8` is unchanged, including its suffix outside the content budget.
  `_utf8_text_bytes` remains distinct from wire-buffer accounting.

No caller is migrated to a different output policy. Helpers, Sender, Output,
Presentation, pacing, timers, deferred queues and worker interception remain
unchanged. The new helper is private and not added to exports. No SQL schema,
migration, private configuration, VERSION or service change is included.

## Regression and test-growth policy

Extend `1302_mb879_text_budget_contracts.t` with nine assertions, retaining its
186 existing assertions. Add no numbered case or duplicated historical
algorithm to the repository. The default full catalogue remains 1,156 files.

The additions cover representation at an ASCII tail and prefix, whitespace
cleanup, normalization order, scalar context, and two long-input work bounds
with exact expected first chunks. Work is measured through the real wire-byte
counter rather than machine-dependent timing thresholds. Against the original
module, the two work bounds fail and all other assertions pass. A temporary
mutation returning the window instead of the original final buffer fails the
new representation regression.

Qualification outside the permanent suite compares 18,900 before/after results
from the actual original and candidate modules. It includes fixed boundaries,
seeded mixed inputs, byte buffers, Unicode whitespace, styles, combining marks,
emoji, exceptional code points, invalid budgets, list/scalar context and prefix
requests. Wire bytes, UTF-8 flags, warnings and errors match. This is sampled
evidence, not a proof for every possible Perl scalar.

All targeted IRC, TMDB, renderer, timer and output cases run with the full suite
before installation is accepted. The package's qualification report records
local results and limitations. The installer accepts no failing server test.
