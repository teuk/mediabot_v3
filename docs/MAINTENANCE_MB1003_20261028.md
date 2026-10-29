# MB1003 — Check weather cache age at use time

Base: `snap_mediabot_v3_teuk_20261028_201600.zip`, VERSION
`3.6dev-20261028_191542`, including MB1002.

The normal weather command accepted negative cache ages as fresh. A backward
clock adjustment could therefore keep a now-future entry fresh until the clock
caught up. Its provider-failure fallback also reused the time captured before
HTTP: an entry could expire while the request ran and still be displayed as
valid cached weather. A clock adjustment during HTTP was ignored there too.

Only `Mediabot/External/Weather.pm` changes at runtime. Fresh reuse requires a
defined timestamp with an age from zero to 180 seconds, inclusive. The fallback
recomputes age after the request and requires zero to 900 seconds, inclusive.
The existing HTTP-error and provider-unhappy paths share that check. Successful
responses are dated when stored, so their cache lifetime starts at completion;
cache pruning uses that same current time.

The configured thresholds, returned text, cached suffix, normal error messages,
location normalization, URL encoding, HTTP timeout/TLS settings, Weather gate,
reply destinations, audit and 200-entry bound remain unchanged. Comparison and
the meteo dispatch adapters are untouched; ordinary meteo uses this same client.
No schema, configuration, dependency or activation changes are required.

`1378_mb1003_weather_cache_clock.t` adds nine focused assertions through the
real command registry and Context with a controlled clock and offline HTTP.
It covers both fresh boundaries, a future entry, both stale boundaries,
expiration during HTTP errors or an unhappy reply, rollback during a failed
request, response-time stamping across forward/backward adjustments, undated
cache recovery and unchanged fallback cache/audit behavior. Five assertions
fail on the unchanged snapshot; all nine pass after correction. No real wait,
external network, IRC connection or SQL server is used.

Acceptance retains the full unfiltered suite with `--progress`, security audit
and startup integrity checks before restarting only dev and invoking native
`commit.sh`. Any failed check must stop the procedure.
