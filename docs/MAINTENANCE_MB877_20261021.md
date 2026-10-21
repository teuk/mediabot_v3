# MB877 — TMDB optional metadata and UTF-8 reply limits

Base: `snap_mediabot_v3_teuk_20261021_131929.zip`, after MB876,
`3.6dev-20261021_111222`.

## Optional metadata must be usable

The response root and result list were already guarded, and title fallback
already ignored non-scalar values. The other display fields still trusted
JSON leaves. An object/array could appear as a Perl reference in the synopsis;
booleans could become a synopsis or rating, and malformed numeric text could
be formatted as a misleading zero with a conversion warning. An unusable
release-date value could also prevent the existing first-air-date fallback.

The command now accepts a defined, nonblank scalar synopsis and otherwise uses
`No synopsis available.`. Meaningful source whitespace is retained. Dates use
the existing scalar/nonempty helper, so an invalid release-date container
cannot hide a usable first-air date. The existing four-digit year extraction
is unchanged; this does not add calendar-date validation.

A vote must be a non-reference numeric scalar and finite before formatting.
An unusable vote is `?`, rather than a reference address, fabricated zero or
infinity. Valid zero, decimal and scientific notation keep one-decimal
formatting. This change does not add a rating-range clamp. Existing missing
and null placeholders, original-title fallback, first movie/TV selection and
HTTP error paths are retained.

## Fit the complete reply in wire bytes

The final reply was limited with character length. Accented text, CJK and
emoji can fit that character limit while exceeding the encoded UTF-8 budget.
Downstream IRC splitting then produces additional lines, sometimes without
the command's intended truncation marker.

The complete reply now uses the existing `_irc_wire_bytes` measurement and
`_irc_prefix_for_budget` helper. The three ASCII dots are reserved inside the
budget, and the established word/punctuation cleanup remains in place.
The splitter sees at most the first budget-sized character prefix: later
characters cannot fit, so the rest of a long synopsis need not be split.

Configuration still clamps `MAIN_PROG_MAXLEN` to 120–900; the limit now applies
to encoded payload bytes. At the normal 400-byte setting and below, a reply
fits one downstream IRC chunk. Configurations above 400 still permit the
existing downstream transport to split into multiple chunks; no change to
the shared 400-byte transport limit is included. UTF-8 character boundaries
are preserved; this patch does not introduce grapheme-based truncation.

## Executable coverage

- `1298_mb877_tmdb_optional_fields.t`: malformed synopsis/date/rating leaves,
  both booleans, nonnumeric/non-finite votes, finite compatibility, missing and
  null values, blank synopsis, original-title fallback and HTTP/TLS settings.
- `1299_mb877_tmdb_utf8_budget.t`: complete replies with accents, emoji, CJK,
  overlong titles/nicknames, three budgets, UTF-8 validity, downstream message
  count at up to 400 bytes, configuration bounds and exact ASCII examples.
- `MB877TMDBFixture.pm`: real built-in tmdb handler, Context, HTTP response
  decoding, result iteration and rendering. Only external IO, configuration
  and channel-language lookup use local fixtures.

The historical truncation test checks the new byte measurement instead of
the superseded character measurement; its remaining assertions are retained.
A separate differential check compares 160 actual-handler ASCII replies from
the intact and corrected code across varying text/title lengths and budgets.

Only the TMDB section and two core imports change in production Claude.pm.
HTTP timeout, verified TLS, endpoint, query/language escaping, selected result,
nick/channel destination and other AI handlers retain their behavior. No SQL
schema, migration, private configuration, VERSION, service or test-runner
change. No real API, IRC server or production database is used by the new
tests. Executed results and local limitations are in `QUALIFICATION.md`.
