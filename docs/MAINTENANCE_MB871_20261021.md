# MB871 — case-preserving Facebook and X metadata caches

Base: `snap_mediabot_v3_teuk_20261021_052641.zip`, after MB870,
`3.6dev-20261021_032548`.

## Correct metadata identity after URL admission

MB864 made the shared URL admission gate preserve resource case. The dedicated
Facebook and X/Twitter handlers still lowercased their entire metadata cache
keys. A second case-distinct URL could pass admission and then receive the
first URL's cached title, without fetching its own resource.

For example, `facebook.com/posts/pfbidAbC123` and
`facebook.com/posts/pfbidabc123`, or `x.com/i/spaces/1AbC123` and
`x.com/i/spaces/1abc123`, occupied the same metadata entry. Query values and
fragments had the same collision. URL resource components are kept opaque;
the bot does not infer whether a particular remote service treats them as
equivalent.

Both handlers now use the existing `_url_cache_identity()` helper for metadata
lookup and storage. Only scheme and host case is folded. Paths, query strings,
fragments and escapes keep their original spelling. The key is used only for
cache identity; it does not replace the URL passed to HTTP or Chromium.

Facebook still computes its key after the existing HTTP-to-HTTPS and bare-host
normalization. X/Twitter still computes its key from the caller's URL, keeping
the previous distinction between `x.com`, `www.x.com` and Twitter aliases, and
between HTTP and HTTPS cache entries. Its browser/API normalization is unchanged.

## Preserved behavior

- Ten-minute metadata expiry and five-minute channel repeat suppression.
- Case-insensitive scheme/host identity and channel repeat identity.
- Current nick and channel when replaying a cached formatted message.
- Facebook's HTTP crawler request, Chromium fallback for non-Reel shells and
  immediate deterministic Reel fallback.
- X/Twitter's API fast path, browser fallback, deterministic URL labels and
  repair of legacy cache entries without a message.
- Chanset checks before admission, private-literal rejection, supported-host
  boundaries, transport settings and existing message limits.

The caches remain process-local. There is no persisted cache migration, database
change, private configuration change or service deployment in this package.
Distinct resource spellings now require distinct cache entries and their first
fetch; equivalent scheme/host spellings still reuse the matching entry.

## Offline regression coverage

`1286_mb871_facebook_cache_identity.t` exercises actual URL dispatch, admission,
Facebook normalization, HTTP title parsing, UTF-8 formatting, metadata replay,
expiry, browser fallback, Reel shells and disabled-feature admission.

`1287_mb871_x_cache_identity.t` exercises actual dispatch and dedicated handling
on both X and Twitter hosts, case-distinct paths/queries/fragments, metadata
replay, expiry, legacy-entry repair, normal API posts with counters, shell
fallbacks, disabled features and lookalike-host rejection.

HTTP responses and browser output are local fixtures. No live API, Chromium
process, IRC connection, database or sleep is required by the new tests. These
tests check the bot's resource selection and cache behavior; they do not claim
to validate the current public HTML of either service.

Executed results and local environment limitations are in the package's
`QUALIFICATION.md`.
