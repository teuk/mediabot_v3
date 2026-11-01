# MB1051 — Keep seen scoped on all supported IRC channel types

`seen` used its own `^#` checks to recognize an explicit or current channel.
Mediabot's Context and IRC output already recognize `#`, `&`, `!` and `+`.
Consequently `seen Alice` in `&local`, or a private `seen Alice &local`, could
ignore the intended channel and return a newer observation from another one.
The same mismatch affected wildcard searches, online shortcuts and the legacy
CHANNEL_LOG/archive fallback. Its activity hint recognized only `#` and `&`.

`Mediabot::Users::Seen` now resolves scope once, before choosing the exact or
wildcard branch, through `Mediabot::Helpers::isIrcChannelTarget`. The explicit
channel still overrides the current one. Both lookup branches share this scope,
as do online filtering, persisted SQL and archive fallback. The existing unknown-
channel guard remains authoritative instead of allowing a global fallback.
The best-effort activity hint uses the same shared classifier.

The classifier supplies the project's existing target recognition; it is not
new channel syntax validation, IRC CASEMAPPING or an authorization policy.
The established no-channel private global lookup remains available. Reply
destinations, message formats, LIKE escaping, SQL bounds and error handling
retain their existing behavior. #channel handling is unchanged.

## Validation

`1424_mb1051_seen_channel_prefix_scope.t` runs the native Mediabot facade and
Seen handler with an in-memory SQLite database, current data and a real local
archive table. Newer unrelated records and an unrelated online nickname expose
scope leakage. Only output/logging and the nickname source are local doubles;
the sole SQL dialect adaptation is the existing 24-hour MySQL interval.

Thirty-seven assertions cover each supported prefix with explicit/current
scope, exact and wildcard requests, literal underscore matching, activity hints,
online name casing, archive selection, reply routing, unknown/empty channels,
unchanged private global requests and warning-free execution. Twenty-five fail
on the unchanged public runtime; twelve pass. All thirty-seven pass after the
correction. No historical test or assertion is modified or suppressed.

The delivery qualification records targeted/full results, any baseline failure
and a clean public apply/test/reverse round trip. There is no live IRC, external
HTTP, MariaDB server or paid provider call during these regression tests.

## Operator flow

The package applies idempotently and requires the full visible suite with
`--progress`, security audit, startup integrity, generated command inventory
and whitespace checks. Only after success does it restart `mediabot@dev.service`
and require a new positive PID stable for ten seconds before invoking the
installed interactive `commit.sh --skip-preflight` for commit/push. VERSION is
not edited by the patch; its existing native 3.8dev progression remains in charge.
No production deployment, schema migration, configuration or dependency change
is part of this delivery. The private commit helper is not shipped.
