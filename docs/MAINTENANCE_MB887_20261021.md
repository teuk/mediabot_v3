# MB887 — Apple Music metadata contracts

Date: 2026-10-21. Base: `snap_mediabot_v3_teuk_20261021_181502.zip`,
after MB886, VERSION `3.6dev-20261021_160327`.

## Reproduced problems

Controlled JSON responses through the real handler reproduce these failures:

| Input | Before | After |
| --- | --- | --- |
| Lookup `trackName` is an object | Displays `HASH(...)`, no page recovery | Rejects the title and permits the existing HTTP/page fallback |
| Usable title with nested artist or album values | Displays `HASH(...)` or `ARRAY(...)` in details | Keeps the title and omits malformed optional leaves |
| `trackTimeMillis` is a 400-digit value | Displays `InfhNaNmNaNs` | Omits the unusable duration |

These are fixture reproductions, not claims of an observed Apple outage.

## Implementation

Only `Mediabot::External::AppleMusic` changes in application code.

- Require a defined, non-reference, nonblank title before accepting a lookup
  result or sending a completed worker result. The scalar value `0` remains
  usable. A rejected lookup follows the existing page fallback.
- Accept only scalar artist/album/date leaves from lookup data. Filter nested
  or null entries from JSON-LD type and artist lists, preserving usable entry
  order. Retain the existing track-array count fallback.
- Validate duration components before formatting. Milliseconds use ASCII
  decimal digits and a finite positive total. ISO components must be numeric
  and finite. Rejected values cause no arithmetic warnings; fractional seconds
  retain the existing floor behavior for usable input.
- Independently copy the six scalar display leaves at the worker boundary.
  Keep the received result untouched. An unusable title produces no AppleMusic
  cache entry or output, and the existing pending cleanup permits a later retry.

The current `[AppleMusic]` badge, colors, reset bytes and character
representation remain intact. Valid metadata formatting, title normalization,
artist deduplication, lookup identity, HTTP/Chromium fallbacks, cache keys and
600-second TTL, worker options, completion guard and legacy truncation remain
unchanged. Duration grammar and formatting remain intact for previously usable
values; malformed numeric components are rejected.

No SQL schema, migration, private configuration, VERSION, service, routing,
other provider, timer or generic URL policy changes are included.

## Validation and test growth

Extend the existing `855_mb672_applemusic_lookup_async.t` by 14 assertions,
from 30 to 44. They execute real lookup, JSON-LD and worker completion paths
with controlled transport: required-title recovery, optional-field omission,
mixed valid/invalid artist entries, numeric duration failure, pending/cache
state, retry, duplicate completion, scalar zero and input preservation.
No new numbered case or fixture file is added.

Against the original module, 11 of the 44 assertions fail. Against the
candidate, all 44 pass; the 13-file targeted group passes 472 assertions.
The other 1,155 existing case files remain byte-identical, and all 1,156 cases
remain selected by the default full suite.

Qualification outside the permanent suite compares 160 before/after results
for retained behavior: valid lookup/page/worker scenarios, byte/UTF-8 flags,
cache and pending state, error/call traces, duration boundaries and 100 seeded
valid numeric examples. They match. This sampled evidence is not a proof for
every possible Perl input. Full-suite results, local limitations and installer
rehearsal are recorded in the package qualification report.
