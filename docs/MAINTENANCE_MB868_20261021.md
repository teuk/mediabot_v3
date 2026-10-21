# MB868 — relative redirects and RSS validators

Base: `snap_mediabot_v3_teuk_20261021_042115.zip`, after MB867,
`3.6dev-20261021_021927`.

## Plugin HTTP redirect resolution

The previous resolver concatenated strings. A redirect `../latest` from
`https://api.example.test/a/b/feed` retained `/a/b/../latest` in the request
target. More seriously, a base such as `https://api.example.test?old=1`
redirected to `?page=2` became `https://api.example.test?old=1/?page=2`,
retaining the old query and requesting the wrong resource.

Normalize a query-only URL's empty path to `/`, then resolve Location with the
existing project dependency `URI`. Relative directory segments and query
replacement follow URI resolution; path/query case and percent-encoded segments
remain intact. Reject whitespace and controls before URI parsing can escape them.

Each resulting URL still passes the existing HTTPS/port/credentials/fragment
policy and destination DNS validation before transport. Private destinations
remain blocked. Numeric peer pinning, certificate verification, the two-redirect
budget, worker ownership and caller-specific response caching are retained.

Reference: [RFC 3986, relative resolution examples, section 5.4](https://www.rfc-editor.org/rfc/rfc3986.html#section-5.4).

## RSS validators belong to the accepted representation

`record_not_modified` previously delegated to the same repository method as a
new body. That method used `COALESCE` for both cases, so a complete response
without ETag or Last-Modified retained validators of an earlier body. Subsequent
polls sent those stale conditional headers.

The shared health update now has two explicit modes:

| Poll outcome | Stored validators |
| --- | --- |
| New body accepted and persisted | Replace both fields; absent fields become NULL |
| 304 Not Modified | Update supplied fields; preserve fields absent from the 304 |
| Fetch or parsing failure | Retain the previous fields |

SQL uses the existing columns and bound values. No schema or migration changes.
Pending item selection, baseline suppression, announcement pacing and poll
timestamps keep their existing behavior.

Reference: [RFC 9111, handling validation responses, section 4.3.3](https://www.rfc-editor.org/rfc/rfc9111.html#section-4.3.3).

## Regression coverage

- `1281_mb868_plugin_http_relative_redirects.t`: exact request targets for
  relative, query-only and cross-origin HTTPS redirects; encoded paths and case;
  rejection of unsafe targets; redirect bound; public async fetch and cache.
- `1282_mb868_rss_validator_lifecycle.t`: actual repository UPDATE statements
  against disposable SQLite, each combination of supplied/absent validators,
  health/error updates and two-poll cycles through the real fetcher and poller.
- `902_mb693_rss_repository_polling.t`: the legacy source assertion now checks
  the shared health-update path rather than requiring COALESCE for every body.

HTTP and DNS are local fixtures. The RSS test database is in memory and exists
only for the duration of the test. No live IRC connection or production database
is used by these new tests. Full validation results are in the package's
`QUALIFICATION.md`.
