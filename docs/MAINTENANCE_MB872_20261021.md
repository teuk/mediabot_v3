# MB872 — weather location spelling and bounded cache growth

Base: `snap_mediabot_v3_teuk_20261021_102642.zip`, after MB871,
`3.6dev-20261021_074543`.

## Preserve spaces in location names

The weather handler rewrote spaces into commas before URL encoding. For
example, `New York` became `New,York`, `Salt Lake City` became `Salt,Lake,City`
and `São Paulo` became `São,Paulo`. This changed the location sent to the
provider, its cache identity and its audit log. It also prevented the existing
weather comparison from finding a multiword city under its actual name.

The extra comma substitution is removed. The existing byte-safe encoder sends
`New York` as `New%20York`, handling both IRC UTF-8 bytes and Perl character
strings without double encoding. The official wttr.in usage documentation
supports multiword locations, including Salt Lake City and Vostok Station:
<https://github.com/chubin/wttr.in#usage>.

The existing terminal two-letter `City CC` shortcut remains unchanged: `Paris
FR` still becomes `Paris,FR`, and `New York US` still becomes `New York,US`.
Explicit commas and latitude/longitude input keep their spelling. This patch
does not redesign the existing country-code heuristic or command tokenizer.
`New York` and an explicitly comma-separated `New,York` are distinct queries.

## Enforce the existing cache limit

The weather cache declared a 200-entry limit but only removed entries older
than fifteen minutes. A burst of distinct locations could therefore grow the
map without a count bound while all entries were recent.

After a successful write exceeds 200 entries, the handler still removes
expired entries first. It then removes the oldest excess entries by stored
timestamp, using lexical key order to break ties. The current response is
retained so its next request can reuse the successful fetch. This is an
oldest-insertion/refresh policy, not an LRU policy; fresh cache reads do not
renew timestamps.

Cache hits remain fresh for three minutes. Provider errors can still replay
data no older than fifteen minutes with the existing `(cached)` marker.
Failed refreshes do not replace the text or renew its timestamp. A successful
refresh replaces both. Cleanup remains lazy at successful write time.

Distinct locations can evict older usable entries once the cache is full.
Revisiting an evicted location requires a new fetch, and outage fallback is
available only for entries still retained. No persistent state is migrated.

## Offline runtime coverage

- `1288_mb872_weather_location_contract.t`: actual weather handler through the
  existing External facade and real command contexts; compound cities,
  country qualifiers, coordinates, UTF-8 byte/character input, actual outgoing
  URLs, replies, cache identities, audit locations, HTTP options, fresh replay,
  existing comparison and disabled/private/syntax guards.
- `1289_mb872_weather_cache_bound.t`: seeded recent/expired/tied timestamps,
  205 actual successful handler requests, retained data, current-response
  preservation, expiry-first eviction, HTTP/text/transport failures, usable
  stale fallback, expired fallback refusal and successful refresh.

Fixtures replace only HTTP and delivery/chanset/audit boundaries. These tests
do not use live weather, a browser, IRC or a production database, and do not
sleep. They verify the requested location and cache behavior rather than the
provider's current geocoding accuracy.

The weather HTTP timeout remains four seconds with verified TLS, French-first
language preference, metric units and the configured User-Agent. Weather and
meteo still use the same handler. YouTube, Fortnite and comparison production
code are unchanged. No SQL schema, migration, private configuration, VERSION
or service deployment is included.

Executed results and local environment limitations are in the package's
`QUALIFICATION.md`.
