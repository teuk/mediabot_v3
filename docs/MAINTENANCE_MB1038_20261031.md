# MB1038 — Metrics cache expiry after a clock rewind

Reviewed snapshot: `snap_mediabot_v3_teuk_20261031_134658.zip`.
Base: `a754c6b859197eff0c9d314c8e84efad2c96ac09` (MB1037),
VERSION `3.8dev-20261031_104721`.

The Prometheus renderer accepted every cache age below five seconds, including
negative ages. After wall time moved backward, a response generated at the old
future timestamp could hide new counter, gauge and histogram observations for
the whole clock difference plus the normal TTL.

The cache is now reusable only when its age is nonnegative and below five
seconds. A rewind refreshes the next response; that replacement then follows
the existing five-second reuse/expiry policy. The correction does not invalidate
on every write or remove the cache.

Twelve assertions call the real metrics HTTP router, renderer and byte encoder
with a controlled clock and native metric mutation APIs. Four fail before the
fix; all twelve pass afterward. They cover one-second/hour rewinds, subsequent
cache reuse and exact expiry, ordinary time, a forward-day jump and disabled
metrics. Responses must retain valid byte Content-Length and UTF-8 labels.
The new test starts no listener, sleeps nowhere and contacts no provider.

The clock source and uptime calculation are unchanged. This fixes snapshot
freshness; it does not introduce a monotonic clock or redefine duration gauges.
There is no radio/YouTube, SQL/schema, configuration or dependency change.
The delivery requires the full --progress suite and native audits before a
dev-only restart and the automatic native 3.8dev commit flow. No manual VERSION
edit, release/tag or production operation is included.
