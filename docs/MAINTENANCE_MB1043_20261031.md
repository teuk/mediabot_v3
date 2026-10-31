# MB1043 — Contain task callback exception objects

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_155714.zip`.
Base: `e4819be669b722713564f1794af6bf28464806af` (MB1042),
VERSION `3.8dev-20261031_145659`.

The shared Scheduler callback helper caught a thrown value but then tested its
truthiness and interpolated it outside the guard. Perl exception objects can
overload boolean or string conversion. A throwing overload escaped into the
event loop; a false-valued exception was not counted or logged. For a calendar
task, an escaped formatter also prevented the next occurrence from being armed.

The helper now records eval completion explicitly. A false callback return is
still success, but every thrown value is a failure. Existing task identity and
lifecycle checks remain in place before updating exception counters. Reference
exceptions become a fixed scalar diagnostic without invoking overloads. Scalar
errors keep their existing whitespace normalization and their payload is bounded
to 512 characters. Callback timing and best-effort metrics are preserved.

Eighteen assertions execute native IO::Async periodic/countdown callbacks and a
healthy peer task. Three throwable classes exercise throwing string conversion,
throwing boolean conversion and false-valued exceptions in both task modes.
Calendar cases rearm and stop on a second actual occurrence. Only countdown
delay is shortened; the resolver still returns a real valid future epoch.
Logging and metrics sinks are in-memory, while Scheduler and timers are their
production implementations. No worker, network, SQL server or listener is used.
Tests also cover ordinary multiline errors, zero callback results, long scalar
errors, a callback replacing its own registration, optional logging/metrics,
restored loop ownership and cleanup. Fifteen fail before correction; all
eighteen pass afterward.

The existing MB556 source guard now also recognizes an explicit eval-success
marker; its single-guard assertion and all other existing assertions remain active.

This change concerns executed task bodies. Date-resolver and timer setup/error
policies, logger implementation, task identities and timer cadence are unchanged.
The delivery requires the full --progress suite and audits before a dev-only
restart and native automatic 3.8dev commit/push. VERSION is not edited manually.
No production SQL/schema, configuration, dependency, radio or YouTube change.
