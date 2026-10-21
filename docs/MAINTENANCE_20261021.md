# Mediabot maintenance — 21 October 2026

## MB867 scope

Reviewed the supplied `snap_mediabot_v3_teuk_20261021_033538.zip`, including
YouTube metadata/search, RSS fetch/pacing, plugin HTTP transport, dynamic
templates, RandomQuote state/runtime, URL shortening and numeric conversion.
This is a bounded maintenance round, not a claim of exhaustive application
coverage. The delivered changes affect three runtime modules, two regression
files, this note and the changelog.

## Reproduced failures and corrections

### Public YouTube metadata

MB866 already protects `getYoutubeDetails`, used by radio metadata. Its public
counterpart `displayYoutubeDetails` still accepted an array root and then read
`items` as a hash field. A successful HTTP response containing `[]` or `[{}]`
raised `Not a HASH reference`. The public reader now requires a JSON object.
Malformed roots remain unavailable metadata; they produce no fabricated title
and no extra request. Healthy public output keeps its channel and formatting.

### YouTube search

`ytSearch_ctx` dereferenced search and metadata entries before checking their
types. A scalar item or a scalar `contentDetails`/`statistics` container could
abort the command. Reference-valued title fields also appeared as Perl object
addresses in replies. The command now admits only object entries with an exact
11-character scalar video ID and a snippet object, and normalizes unexpected
optional containers/title fields before rendering.

The API request's `maxResults` parameter was the only effective result bound.
An oversized or duplicate response could produce more messages than configured,
including on subsequent cache hits. Admission now deduplicates exact IDs and
stops at the configured limit of 1–5 videos. The header counts admitted entries;
metadata lookup requests those entries in search order and ignores unrequested
metadata identities. Existing duration/view formatting, permission gating,
logging and cache reuse remain covered.

### RSS and plugin IPv6 transport

Both default HTTP requesters constructed their preferred-peer list using two
unparenthesized `grep` expressions. Perl included the second expression in the
first expression's input list, so the IPv4 filter removed every IPv6 address.
IPv6-only destinations made zero connection attempts; a failed IPv4 transport
could not fall back to an otherwise validated IPv6 address.

Parenthesizing each filter restores both address families while preserving
IPv4 preference and resolver order within each family. Tests exercise the real
requesters and the RSS/plugin URL-validation wrappers with substituted HTTP I/O.
They cover IPv6-only success, cross-family and same-family fallback, transport
exceptions, all-peer failures, HTTP errors that must not be retried, public/private
destination admission, exact peer pinning, original URL identity, TLS verification,
redirect policy and the existing RSS four-attempt budget. No external endpoint
is contacted by these regressions.

## Validation

The new regressions were run against the original implementation and reproduced
the exceptions, reference leakage, excessive search output and missing IPv6
attempts. After correction, the two new files pass 244 assertions. The wider
targeted runner selection passes 904 assertions across 29 files.

Full-suite and packaging results are recorded in the delivered qualification
report. Validation uses an isolated Perl dependency environment; the final
installer reruns the tests with the target host's dependencies before reporting
success. No live IRC/API or production-database probe is included.

## Compatibility

No database schema or migration, SQL query, private configuration, persistent
state format, provider selection, native updater, service unit or release version
is changed. The development line remains `3.6dev`. Existing MB849–MB866 safeguards
remain in place. Use the project's `commit.sh` workflow after host validation.
