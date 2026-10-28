# MB1001 — Route meteo comparisons through the existing weather comparison

Base: `snap_mediabot_v3_teuk_20261028_192439.zip`, VERSION
`3.6dev-20261028_180215`, including MB1000.

The registry documents `meteo` as an alias for `weather`, but only `weather`
recognized its `compare` subcommand. `meteo compare Paris Lyon` therefore
queried the provider for the fictitious location `compare Paris Lyon`, instead
of comparing the cached cities. Missing comparison arguments also triggered
ordinary city lookups instead of the existing private comparison syntax notice.

Only the `meteo` registry adapter in `Mediabot/Mediabot.pm` changes. It now
uses the same case-insensitive subcommand dispatch as `weather`, removing the
subcommand before calling the existing `mbWeatherCompare_ctx`. Other inputs
still reach the existing `displayWeather_ctx` with their original arguments.

The shared comparison retains its cache-only behavior, per-city freshness
validation, inclusive 900-second limit, missing-data guidance and reply routing.
Ordinary meteo requests retain their Weather chanset gate, channel requirement,
URL encoding, fresh-cache reuse and fetch audit. The original weather adapter,
comparison implementation, provider client, command help and inventory remain
unchanged. No SQL, configuration, dependency, plugin or activation changes.

`1376_mb1001_meteo_compare_alias.t` adds nine focused assertions through the
real command registry and Context. An offline HTTP fixture populates the real
weather cache through both ordinary commands. Cases cover normal alias fetching,
cache-only comparison, keyword/city casing, another destination, the exact age
limit, invalid/expired entries, missing cities, ordinary cache hits, multiword
city encoding and existing gates. Four assertions fail on the original snapshot;
all nine pass with the correction. No external network or SQL is used.

Acceptance retains the unfiltered suite with `--progress`, security audit and
startup integrity checks before restarting only dev and using `commit.sh`.
Any failed check must stop the procedure.
