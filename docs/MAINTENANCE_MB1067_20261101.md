# MB1067 — Unicode word counts

## Defect

wordcount split UTF-8 bytes by allowing every byte >= 0x80 inside a word.
That kept French lowercase accents intact but applied lc to bytes, leaving
uppercase accents unchanged. ÉCOLE, école and a decomposed accent could count
as different words. Unicode punctuation and emoji also stayed inside tokens.
When DBI returned character strings, the same byte-range regex discarded
Greek, Chinese and other characters above U+00FF.

## Implementation

Use the existing decode_irc_text boundary: decode valid UTF-8 once, preserve
already decoded text and retain its existing fallback for invalid legacy bytes.
Normalize canonical Unicode accents with the core Unicode::Normalize module,
already used elsewhere in the project. Apply Unicode casing only inside the
word-count callback, avoiding changes to nick/channel identity elsewhere.

Extract tokens beginning with a letter, number or underscore and continuing
with those characters or combining marks. Punctuation/emoji separate words;
unattached marks and emoji variation selectors do not become standalone words.
Do not remove accents or transliterate distinct letters. Preserve ASCII words,
numeric tokens and underscore behavior.

Both the bounded and streaming-all branches use that same callback. SQL,
row scope, the 50,000-row policy, optional activity rank, top-five tie ordering,
three-character minimum for displayed top words and achievement hook remain
unchanged. That minimum now measures logical characters rather than UTF-8 bytes. All statistics
are computed from copies; no stored message is rewritten. Other commands in
Stats::History and compat's vocabulary tokenizer are outside this change.

## Validation and delivery

Replace the nine checks in 641_mb426_wordcount_accent_safe_split.t with nine
native registry/SQLite assertions. The fixture really switches sqlite_unicode
between raw UTF-8 bytes and characters, checks the actual output/frequencies
and corrected achievement count, bounds the command's user/channel/event scope,
and exercises both default and streaming-all paths.

Cover canonical/case variants of école and café, Greek and Chinese, Unicode
punctuation without spaces, emoji, isolated marks/selectors, ASCII/number/
underscore compatibility, NULL/empty rows, the shared legacy-byte fallback,
absence of warnings and unchanged stored rows. Remove only the obsolete literal
wordcount tokenizer pin from the archive case: the native case now proves that
behavior. Keep its other archive/order assertions and compat guard unchanged.
No new case; one fewer assertion overall.

Preserve all qualified pending changes, including MB1062/63/64/65/66. VERSION,
the private commit helper, README, runner/ETA, radio and YouTube stay unchanged.
The operator script runs a visible full suite with --progress/ETA, audits and
inventory, then dev-only restart and native 3.8dev commit/push after success.
No production service, schema, configuration or dependency installation change.
See package qualification for actual local results and limits.
