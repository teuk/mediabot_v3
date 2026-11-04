# MB1101 — Validate weather replies before publication

## Fault and behavior

Weather treated almost any nonempty HTTP 200 body as a result. A provider or
proxy could return HTML, a challenge, multiple lines or a large body, which was
then sent to IRC and stored for three minutes as valid weather. A failed later
refresh could replay that same body for up to fifteen minutes.

The requested custom wttr format is a single short plain-text line. Validate
that contract before the cache write, output and success audit. Accept absent
Content-Type metadata for compatibility; when supplied, require text/plain
(with optional parameters). Preserve the original character/byte representation,
weather symbols and expressions such as wind <5 km/h. Trim ordinary space/CRLF
framing; reject remaining ASCII controls, HTML markup and lines above 2,048
wire bytes. The HTTP client separately caps the response body at 16 KiB.

An invalid HTTP success follows the existing provider-unhappy fallback. A
confirmed entry no older than fifteen minutes may be displayed with `(cached)`;
otherwise the usual temporary-unavailability message is sent. Check the age
after HTTP completes. Keep the prior text and timestamp unchanged, so failure
does not postpone expiry or prevent the next refresh. Log only a fixed rejection
code, without the external body. Transport status failures retain their existing
path. Cache capacity, three-minute freshness, URL encoding, country suffixes,
metric units, language preference and Weather chanset behavior are unchanged.

## Essential tests

Extend case 1378 through the real command registry for both weather and meteo.
Two grouped assertions cover valid Unicode and raw UTF-8, CRLF framing, the exact
size boundary, HTTP size/timeout/TLS options, configured/fallback User-Agents,
HTML with/without headers, multiline text, ASCII control characters, oversize
Unicode/byte strings, malformed scalar shapes and existing provider errors.
Each invalid response is exercised without cache, with usable stale data, with
expiry during HTTP and with already expired data, followed by a successful
refresh. Assert exact wire, cache timestamp/content, success audit and bounded
logs; capture warnings. No network, sleeps or new child process is needed.

Keep native location/URL, metric-format, chanset, cache-bound, comparison and
clock-boundary tests. Remove cases 102 and 653: their source matching and copied
encoding calculation are superseded by these native fixtures. Two grouped
checks replace seventeen old assertions: fifteen fewer assertions and two
fewer test files/processes. No runtime dependency or schema change.

## Operator workflow and limits

The package validates the cumulative qualified scope and preserves previous
accepted changes. It runs the targeted selection, full suite with --progress,
security/startup/inventory checks, then restarts only mediabot@dev.service.
A distinct positive PID must remain active and stable for ten seconds before
interactive commit.sh. VERSION is left to its native 3.8dev plan.

The parser validates the response shape, not the meteorological truth of an
arbitrary plain sentence returned by the provider. A stable PID is not proof
of IRC reconnection. No production instance is operated by this package.
