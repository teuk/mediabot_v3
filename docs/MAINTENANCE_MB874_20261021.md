# MB874 — horoscope sign validation and efficient Unicode fitting

Base: `snap_mediabot_v3_teuk_20261021_113748.zip`, after MB873,
`3.6dev-20261021_091001`.

## Check malformed declared signs

The provider parser checked the response's sign only when it was a scalar.
A defined array, object or JSON boolean therefore skipped the identity guard
and allowed its forecast to be published under the requested sign. This also
prevented a usable mirror response from being tried.

Every defined declared sign now passes through the existing sign normalizer.
Unusable containers are rejected in the same way as an ordinary wrong sign.
Diagnostics use a fixed label rather than a Perl reference representation.
The configured provider list and its mirror/local recovery behavior are kept.

The sign remains optional for the existing supported provider shapes. Missing
and null sign fields retain their previous compatibility; this correction does
not claim identity evidence where a provider supplies none. Supported aliases,
flat/nested response shapes and correct scalar signs remain usable. A custom
single-provider URL remains a single provider rather than gaining a new mirror.

## Fit a bounded prefix instead of shrinking the whole source

`cap_text()` built all grapheme clusters, removed the last cluster, rejoined
the remainder and encoded the whole remainder repeatedly until it fitted.
For a long response this made truncation quadratic in source length even
though only a small prefix could be displayed.

The formatter now retains the existing whole-input size check, then scans
graphemes from the start, accounting for their encoded sizes until the prefix
budget is full. It reserves the same three UTF-8 bytes for the ellipsis and
applies the existing last-word and trailing-punctuation cleanup.

For the regression's 5,800-character forecast and 380-byte budget, encoder input
work falls from 16,757,824 characters on the intact code to a bounded prefix
plus one full-input size check. Qualification records the corrected measurement.
This is an operation-count assertion rather than a machine-speed benchmark.

Whole combining sequences and joined emoji remain intact. Text already within
budget, undefined text, small budgets, word boundaries and the final ellipsis
keep their established behavior. The provider display budget remains 380 bytes
and the compact IRC formatter remains two payloads of at most 400 UTF-8 bytes.

## Offline regression coverage

- `1292_mb874_horoscope_sign_contract.t`: flat/nested malformed declared signs,
  booleans, correct aliases, missing/null compatibility, wrong scalar signs,
  custom provider URL, HTTP/TLS settings, mirror/local recovery and both real
  public aliases through native CommandAsync fork/pipe/replay.
- `1293_mb874_horoscope_text_budget.t`: explicit legacy output examples,
  accents, emoji, combining sequences, joined family emoji, UTF-8 byte bounds,
  deterministic encoding-work bound and actual compact formatting.

The new tests use local provider responses and fixture IO. They do not contact
an API, IRC server or production database, and introduce no sleeps. Existing
localization/translation, birthday resolution and daily-detail regressions
remain part of the wider qualification.

Only `Mediabot/External/Horoscope.pm` changes in production code. Provider
timeouts and response limits, verified TLS, redirect policy, configured
translation routing, nick/channel delivery, Games guards and the local daily
forecast policy are unchanged. No schema, migration, private configuration,
VERSION or service deployment is included.

Executed results and local environment limitations are in the package's
`QUALIFICATION.md`.
