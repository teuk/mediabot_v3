# MB998 — Bound cached weather comparisons by age

Base: `snap_mediabot_v3_teuk_20261028_180704.zip`, VERSION
`3.6dev-20261028_170642`. Previous corrections remain present.

## Reproduced defect

`weather compare` reused any nonempty cached text without examining its
timestamp. Old observations could therefore remain visible indefinitely
while the normal weather command already limited its stale fallback to
fifteen minutes. Cache cleanup only ran when writing a large cache, so
comparison could not rely on expired entries already having been removed.

Comparison now requires a dated entry with an age from zero to 900 seconds,
inclusive. It checks each city separately. Older, undated or future-dated
entries return the existing no-cached-data guidance to run normal weather
first. Empty or absent entries retain that same behavior.

This uses the existing maximum stale-fallback age, not a new freshness
setting. The normal three-minute fresh-cache policy and provider-failure
fallback in `Mediabot/External/Weather.pm` are unchanged.

Only `mbWeatherCompare_ctx` in `Mediabot/UserCommands.pm` changes at runtime.
Comparison still makes no HTTP request, removes no entry and renews no
timestamp. Valid text, case-insensitive keys, destinations and private syntax
feedback are unchanged. No SQL, configuration, dependency, Trivia, birthday,
plugin or production rollout change is included.

## Verification

Eleven assertions use the real registered weather handler and Context.
An offline HTTP fixture populates the actual weather cache, then a controlled
clock exercises fresh, exactly-900-second and expired entries. Other cases
cover one expired city, future/missing timestamps, absent/empty text,
syntax feedback, case variants, a different destination and normal refresh
restoring a valid comparison. Every comparison verifies unchanged cache data
and request count. Four assertions fail before correction; all eleven pass.

The delivery README records targeted/full suite results, security audit,
startup integrity and command-inventory verification. No test is excluded.
The user procedure runs the complete suite with --progress and stops on
failure before restarting dev and invoking native commit/push.
